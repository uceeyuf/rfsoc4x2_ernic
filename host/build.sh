#!/bin/sh
# Build the host programs (libibverbs from rdma-core: apt install libibverbs-dev).
set -e
cd "$(dirname "$0")"
cc -O2 -Wall -Wextra -o rdma_loopback rdma_loopback.c -libverbs
echo "built $(pwd)/rdma_loopback"
