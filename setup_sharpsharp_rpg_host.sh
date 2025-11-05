#!/bin/bash
# setup_sharpsharp_rpg_host.sh

CTID=120
VMHOST="local:vztmpl/debian-12-standard_12.5-1_amd64.tar.zst"
HOSTNAME="sharpsharp-rpg"
DISK="local-lvm:20"
MEMORY=8192
CORES=4

# 1. 컨테이너 생성
pct create $CTID $VMHOST \
  -hostname $HOSTNAME \
  -cores $CORES \
  -memory $MEMORY \
  -net0 name=eth0,bridge=vmbr0,ip=dhcp \
  -rootfs $DISK,size=40G \
  -features nesting=1 \
  -unprivileged 0

# 2. 시작 및 내부 설치
pct start $CTID
sleep 10
pct exec $CTID -- bash -c "wget -q https://raw.githubusercontent.com/jaehyun-ko/proxmox-helper-scripts/main/setup_sharpsharp_rpg_lxc.sh -O /root/setup_sharpsharp_rpg_lxc.sh && chmod +x /root/setup_sharpsharp_rpg_lxc.sh && /root/setup_sharpsharp_rpg_lxc.sh"
