# shellcheck shell=bash disable=SC2034  # NCCL_ENV / NCCL_MASTER are used by the scripts that source this file
# kit/lib/nccl.sh — NCCL network profiles for DGX Spark clusters. Sourced by recipes AND by the kit's NCCL test,
# so the test proves exactly the settings the recipe will run with. Reads cluster.env variables (TP2_*, TP3_HCAS,
# IB_GID_INDEX, LAN_IF). Each function fills the bash array NCCL_ENV with docker `-e` arguments.

# pair: two Sparks, one QSFP cable. Bootstrap and data both on the cabled port.
# Buffers/protocol as in the triangle profile: without them a 1 MB all-reduce took ~490 us (slower than 4 MB);
# with them ~138 us, 4 MB bus bandwidth 9.3 -> 11.4 GB/s, small messages unchanged (measured 2026-09-26).
# NCCL_PROTO=^LL128 alone was erratic — keep the set together.
#   nccl_env_pair RANK        (0 = head, 1 = worker)
nccl_env_pair() {
  local fab_if hca
  if [ "$1" = 0 ]; then fab_if=$TP2_HEAD_IF; hca=$TP2_HEAD_HCA; else fab_if=$TP2_WORKER_IF; hca=$TP2_WORKER_HCA; fi
  # GID not pinned by default: NCCL picks the IPv4 GID from ADDR_FAMILY + ADDR_RANGE. Pin with IB_GID_INDEX_TP2=N.
  NCCL_ENV=(-e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA="$hca"
            ${IB_GID_INDEX_TP2:+-e NCCL_IB_GID_INDEX=$IB_GID_INDEX_TP2}
            -e NCCL_IB_ROCE_VERSION_NUM=2 -e NCCL_IB_ADDR_FAMILY=AF_INET -e NCCL_IB_ADDR_RANGE="$TP2_SUBNET"
            -e NCCL_SOCKET_IFNAME="$fab_if" -e GLOO_SOCKET_IFNAME="$fab_if" -e TP_SOCKET_IFNAME="$fab_if" -e MN_IF_NAME="$fab_if"
            -e NCCL_NVLS_ENABLE=0 -e NCCL_CROSS_NIC=0 -e NCCL_IB_MERGE_NICS=0 -e NCCL_CUMEM_ENABLE=0
            -e NCCL_BUFFSIZE=1048576 -e NCCL_LL128_BUFFSIZE=262144 -e NCCL_PROTO=^LL128
            -e NCCL_MAX_NCHANNELS="${NCCL_CHANNELS:-8}" ${NCCL_CHANNELS:+-e NCCL_MIN_NCHANNELS="$NCCL_CHANNELS"}
            -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_DEBUG="${NCCL_DEBUG:-WARN}" -e TORCH_NCCL_ASYNC_ERROR_HANDLING=1)
  NCCL_MASTER=$TP2_HEAD_IP
}

# triangle: three Sparks, each port cabled to a different neighbour, no switch. Bootstrap over the LAN, data over
# both CX7 ports. Each port reaches ONE neighbour, so NCCL must not merge them (MERGE_NICS=0, SUBNET_AWARE_ROUTING=1)
# or it tries a peer through the wrong port and times out in ibv_modify_qp (110). P2P/SHM off; small buffers because
# pinned host memory is GPU memory on a Spark.
#   nccl_env_triangle RANK
nccl_env_triangle() {
  NCCL_ENV=(-e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA="$TP3_HCAS" -e NCCL_IB_GID_INDEX="${IB_GID_INDEX:-5}"
            -e NCCL_SOCKET_IFNAME="$LAN_IF" -e GLOO_SOCKET_IFNAME="$LAN_IF" -e TP_SOCKET_IFNAME="$LAN_IF" -e MN_IF_NAME="$LAN_IF"
            -e NCCL_P2P_DISABLE=1 -e NCCL_SHM_DISABLE=1 -e NCCL_NVLS_ENABLE=0 -e NCCL_CUMEM_ENABLE=0
            -e NCCL_IB_MERGE_NICS=0 -e NCCL_CROSS_NIC=1 -e NCCL_IB_SUBNET_AWARE_ROUTING=1
            -e NCCL_BUFFSIZE=1048576 -e NCCL_LL128_BUFFSIZE=262144 -e NCCL_PROTO=^LL128
            -e NCCL_MAX_NCHANNELS="${NCCL_CHANNELS:-8}" ${NCCL_CHANNELS:+-e NCCL_MIN_NCHANNELS="$NCCL_CHANNELS"}
            -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_DEBUG="${NCCL_DEBUG:-WARN}" -e TORCH_NCCL_ASYNC_ERROR_HANDLING=1)
  NCCL_MASTER=${LAN_IPS[0]}
}

