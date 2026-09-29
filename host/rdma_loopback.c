// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Yijie Yu
//
// rdma_loopback - RDMA memory loopback through ERNIC on the RFSoC 4x2 (RoCE v2, RC QP).
//
// The host RDMA WRITEs a pattern into a memory region of the FPGA (PL DDR4), RDMA READs it back
// into a second buffer and compares; both directions are timed. No connection manager: the QP
// is connected by hand. The host QP number, MAC and PSN go to a file for the FPGA side
// (tests/ernic_config.tcl programs ERNIC with them); the program waits until that file's
// "ready" twin appears, then moves the QP to RTS.
//
//   sudo ./rdma_loopback [--dev NAME (default: the first RDMA device)] [--gid-index N] [--fpga-ip 192.168.100.1] [--fpga-qpn 2]
//        [--va 0x10000000] [--rkey 0x12] [--size MB] [--chunk KB] [--depth N] [--iters N]
//        [--psn N] [--params FILE]
//
// Host side: the interface has 192.168.100.2/24 and MTU >= 4200, and a static neighbour entry
// for the FPGA (its MAC, the FPGA does not answer ARP).

#include <arpa/inet.h>
#include <errno.h>
#include <infiniband/verbs.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static struct {
    const char *dev, *params;
    int gid_index, fpga_qpn, depth, iters;
    uint32_t fpga_ip, rkey, psn;
    uint64_t va, size, chunk;
} O = {.dev = NULL, .params = "rdma_host_params.txt", .gid_index = -1, .fpga_qpn = 2, .depth = 32,
       .iters = 3, .rkey = 0x12, .psn = 0x100, .va = 0x10000000, .size = 256ull << 20, .chunk = 1ull << 20};

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void die(const char *m) { fprintf(stderr, "%s: %s\n", m, strerror(errno)); exit(1); }

// RoCE v2 GID holding an IPv4-mapped address (::ffff:a.b.c.d)
static int find_gid(struct ibv_context *ctx, union ibv_gid *gid)
{
    for (int i = 0; i < 256; i++) {
        union ibv_gid g;
        if (ibv_query_gid(ctx, 1, i, &g)) break;
        char path[256], type[64] = "";
        snprintf(path, sizeof(path), "/sys/class/infiniband/%s/ports/1/gid_attrs/types/%d", O.dev, i);
        FILE *f = fopen(path, "r");
        if (f) { if (!fgets(type, sizeof(type), f)) type[0] = 0; fclose(f); }
        static const uint8_t v4mapped[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
        if (strstr(type, "RoCE v2") && !memcmp(g.raw, v4mapped, 12)) { *gid = g; return i; }
    }
    return -1;
}

static void parse(int argc, char **argv)
{
    struct in_addr a;
    inet_pton(AF_INET, "192.168.100.1", &a);
    O.fpga_ip = ntohl(a.s_addr);
    for (int i = 1; i + 1 < argc; i += 2) {
        const char *k = argv[i], *v = argv[i + 1];
        if (!strcmp(k, "--dev")) O.dev = v;
        else if (!strcmp(k, "--gid-index")) O.gid_index = atoi(v);
        else if (!strcmp(k, "--fpga-ip")) { inet_pton(AF_INET, v, &a); O.fpga_ip = ntohl(a.s_addr); }
        else if (!strcmp(k, "--fpga-qpn")) O.fpga_qpn = atoi(v);
        else if (!strcmp(k, "--va")) O.va = strtoull(v, NULL, 0);
        else if (!strcmp(k, "--rkey")) O.rkey = (uint32_t)strtoul(v, NULL, 0);
        else if (!strcmp(k, "--size")) O.size = strtoull(v, NULL, 0) << 20;
        else if (!strcmp(k, "--chunk")) O.chunk = strtoull(v, NULL, 0) << 10;
        else if (!strcmp(k, "--depth")) O.depth = atoi(v);
        else if (!strcmp(k, "--iters")) O.iters = atoi(v);
        else if (!strcmp(k, "--psn")) O.psn = (uint32_t)strtoul(v, NULL, 0);
        else if (!strcmp(k, "--params")) O.params = v;
        else { fprintf(stderr, "unknown option %s\n", k); exit(1); }
    }
}

// post `len` bytes as RDMA WRITE or READ in chunks, at most `depth` in flight; returns seconds
static double transfer(struct ibv_qp *qp, struct ibv_cq *cq, struct ibv_mr *mr, uint8_t *buf,
                       enum ibv_wr_opcode op, int *errors)
{
    uint64_t n = O.size / O.chunk, posted = 0, done = 0;
    double t0 = now();
    while (done < n) {
        while (posted < n && posted - done < (uint64_t)O.depth) {
            struct ibv_sge sge = {.addr = (uintptr_t)(buf + posted * O.chunk), .length = (uint32_t)O.chunk,
                                  .lkey = mr->lkey};
            struct ibv_send_wr wr = {.wr_id = posted, .sg_list = &sge, .num_sge = 1, .opcode = op,
                                     .send_flags = IBV_SEND_SIGNALED}, *bad;
            wr.wr.rdma.remote_addr = O.va + posted * O.chunk;
            wr.wr.rdma.rkey = O.rkey;
            if (ibv_post_send(qp, &wr, &bad)) die("ibv_post_send");
            posted++;
        }
        struct ibv_wc wc[16];
        int k = ibv_poll_cq(cq, 16, wc);
        if (k < 0) die("ibv_poll_cq");
        for (int i = 0; i < k; i++) {
            if (wc[i].status != IBV_WC_SUCCESS) {
                fprintf(stderr, "%s wr %" PRIu64 ": %s (vendor err 0x%x)\n", op == IBV_WR_RDMA_WRITE ? "WRITE" : "READ",
                        wc[i].wr_id, ibv_wc_status_str(wc[i].status), wc[i].vendor_err);
                if (++*errors > 4) exit(1);
            }
        }
        done += (uint64_t)k;
        if (now() - t0 > 30) { fprintf(stderr, "timeout: %" PRIu64 " of %" PRIu64 " done\n", done, n); exit(1); }
    }
    return now() - t0;
}

int main(int argc, char **argv)
{
    parse(argc, argv);
    struct ibv_device **list = ibv_get_device_list(NULL);
    struct ibv_device *d = NULL;
    for (int i = 0; list && list[i]; i++)
        if (!O.dev ? i == 0 : !strcmp(ibv_get_device_name(list[i]), O.dev)) d = list[i];
    if (!d) { fprintf(stderr, "no RDMA device %s\n", O.dev ? O.dev : "at all"); return 1; }
    O.dev = ibv_get_device_name(d);
    struct ibv_context *ctx = ibv_open_device(d);
    if (!ctx) die("ibv_open_device");
    union ibv_gid sgid;
    int gi = O.gid_index >= 0 ? O.gid_index : find_gid(ctx, &sgid);
    if (gi < 0) { fprintf(stderr, "no RoCE v2 IPv4 GID (is 192.168.100.2 on the interface?)\n"); return 1; }
    ibv_query_gid(ctx, 1, gi, &sgid);

    struct ibv_pd *pd = ibv_alloc_pd(ctx);
    // 2 MB aligned and backed by transparent huge pages where possible: fewer NIC address
    // translation misses when READ responses arrive at line rate; touched before registration
    uint64_t asz = (O.size + (2u << 20) - 1) & ~((2ull << 20) - 1);
    uint8_t *wbuf = aligned_alloc(2u << 20, asz), *rbuf = aligned_alloc(2u << 20, asz);
    if (!pd || !wbuf || !rbuf) die("alloc");
    madvise(wbuf, asz, MADV_HUGEPAGE);
    madvise(rbuf, asz, MADV_HUGEPAGE);
    memset(rbuf, 0, asz);
    for (uint64_t i = 0; i < O.size / 8; i++) ((uint64_t *)wbuf)[i] = 0x9E3779B97F4A7C15ull * (i + 1);
    struct ibv_mr *wmr = ibv_reg_mr(pd, wbuf, O.size, IBV_ACCESS_LOCAL_WRITE);
    struct ibv_mr *rmr = ibv_reg_mr(pd, rbuf, O.size, IBV_ACCESS_LOCAL_WRITE);
    if (!wmr || !rmr) die("ibv_reg_mr (run as root or raise the memlock limit)");
    struct ibv_cq *cq = ibv_create_cq(ctx, 1024, NULL, NULL, 0);
    struct ibv_qp_init_attr qia = {.send_cq = cq, .recv_cq = cq, .qp_type = IBV_QPT_RC,
                                   .cap = {.max_send_wr = 512, .max_recv_wr = 16, .max_send_sge = 1, .max_recv_sge = 1}};
    struct ibv_qp *qp = ibv_create_qp(pd, &qia);
    if (!cq || !qp) die("create cq/qp");

    struct ibv_qp_attr a = {.qp_state = IBV_QPS_INIT, .pkey_index = 0, .port_num = 1,
                            .qp_access_flags = IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE};
    if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS)) die("INIT");

    // our MAC: the netdev of the RDMA port
    char path[256], mac[32] = "";
    snprintf(path, sizeof(path), "ls /sys/class/infiniband/%s/device/net | head -1 | xargs -I{} cat /sys/class/net/{}/address", O.dev);
    FILE *f = popen(path, "r");
    if (f) { if (!fgets(mac, sizeof(mac), f)) mac[0] = 0; pclose(f); }
    mac[strcspn(mac, "\n")] = 0;

    char gidstr[64];
    inet_ntop(AF_INET6, sgid.raw, gidstr, sizeof(gidstr));
    printf("host: %s GID[%d] %s  MAC %s  QPN %u  PSN 0x%x\n", O.dev, gi, gidstr, mac, qp->qp_num, O.psn);
    char ready[600];
    snprintf(ready, sizeof(ready), "%s.ready", O.params);
    unlink(ready);
    f = fopen(O.params, "w");
    if (!f) die(O.params);
    fprintf(f, "qpn %u\nmac %s\npsn %u\n", qp->qp_num, mac, O.psn);
    fclose(f);
    printf("waiting for the FPGA side (%s) ...\n", ready);
    fflush(stdout);
    struct stat st;
    while (stat(ready, &st)) usleep(100000);

    struct ibv_port_attr pa;
    struct ibv_device_attr da;
    if (ibv_query_port(ctx, 1, &pa) || ibv_query_device(ctx, &da)) die("query port/device");
    enum ibv_mtu mtu = pa.active_mtu < IBV_MTU_4096 ? pa.active_mtu : IBV_MTU_4096;
    int rd_atom = da.max_qp_rd_atom < 16 ? da.max_qp_rd_atom : 16;
    printf("port: active MTU %d, max RDMA reads in flight %d\n", 128 << mtu, rd_atom);

    memset(&a, 0, sizeof(a));
    a.qp_state = IBV_QPS_RTR;
    a.path_mtu = mtu;
    a.dest_qp_num = (uint32_t)O.fpga_qpn;
    a.rq_psn = O.psn;
    a.max_dest_rd_atomic = (uint8_t)rd_atom;
    a.min_rnr_timer = 12;
    a.ah_attr.is_global = 1;
    a.ah_attr.port_num = 1;
    a.ah_attr.grh.sgid_index = (uint8_t)gi;
    a.ah_attr.grh.hop_limit = 64;
    uint8_t *dg = a.ah_attr.grh.dgid.raw;
    memset(dg, 0, 16); dg[10] = dg[11] = 0xff;
    dg[12] = O.fpga_ip >> 24; dg[13] = O.fpga_ip >> 16; dg[14] = O.fpga_ip >> 8; dg[15] = O.fpga_ip;
    if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                                  IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER)) die("RTR");
    memset(&a, 0, sizeof(a));
    a.qp_state = IBV_QPS_RTS;
    a.sq_psn = O.psn;
    a.timeout = 14;
    a.retry_cnt = 7;
    a.rnr_retry = 7;
    a.max_rd_atomic = (uint8_t)rd_atom;
    if (ibv_modify_qp(qp, &a, IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                                  IBV_QP_RNR_RETRY | IBV_QP_MAX_QP_RD_ATOMIC)) die("RTS");
    printf("connected to QP %d at %u.%u.%u.%u; %" PRIu64 " MB in %" PRIu64 " KB RDMA ops, %d in flight\n",
           O.fpga_qpn, O.fpga_ip >> 24, (O.fpga_ip >> 16) & 255, (O.fpga_ip >> 8) & 255, O.fpga_ip & 255,
           O.size >> 20, O.chunk >> 10, O.depth);

    int errors = 0;
    for (int it = 1; it <= O.iters; it++) {
        for (uint64_t i = 0; i < O.size / 8; i++) ((uint64_t *)wbuf)[i] ^= (uint64_t)it << 56;
        memset(rbuf, 0, O.size);
        double tw = transfer(qp, cq, wmr, wbuf, IBV_WR_RDMA_WRITE, &errors);
        double tr = transfer(qp, cq, rmr, rbuf, IBV_WR_RDMA_READ, &errors);
        uint64_t bad = 0;
        for (uint64_t i = 0; i < O.size / 8; i++) bad += ((uint64_t *)wbuf)[i] != ((uint64_t *)rbuf)[i];
        printf("run %d: WRITE %.2f Gbit/s   READ %.2f Gbit/s   compare: %s (%" PRIu64 " of %" PRIu64 " words differ)\n",
               it, O.size * 8 / tw / 1e9, O.size * 8 / tr / 1e9, bad ? "MISMATCH" : "identical", bad, O.size / 8);
        fflush(stdout);
    }
    ibv_destroy_qp(qp);
    ibv_destroy_cq(cq);
    ibv_dereg_mr(wmr);
    ibv_dereg_mr(rmr);
    ibv_dealloc_pd(pd);
    ibv_close_device(ctx);
    return errors ? 1 : 0;
}
