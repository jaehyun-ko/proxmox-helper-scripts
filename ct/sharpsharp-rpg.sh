#!/usr/bin/env bash
#=============================================================================
# Title   : SharpSharp RPG Forge Server
# Author  : jaehyun-ko
# License : MIT
#=============================================================================
set -Eeuo pipefail
trap 'echo -e "\n[ERROR] Script failed at line $LINENO\n" >&2' ERR

# shellcheck disable=SC1091
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/functions.sh)

header_info "SharpSharp RPG Forge Server"

APP="SharpSharp RPG Forge Server"
CTID=${CTID:-120}
HNAME=${HNAME:-sharpsharp-rpg}
DISK_SIZE=${DISK_SIZE:-40}
CPU_CORES=${CPU_CORES:-4}
RAM_SIZE=${RAM_SIZE:-8192}
BRG=${BRG:-vmbr0}
STORAGE=${STORAGE:-local}
TEMPLATE=${TEMPLATE:-debian-12-standard_12.12-1_amd64.tar.zst}

FORGE_VER="1.20.1-47.4.0"
PACK_URL="https://mediafilez.forgecdn.net/files/6861/683/%5BSTANDARD%5D%20SharpSharp%20RPG%20Release%201.4.1.zip"

# ---------- LXC 생성 ----------
default_ct_settings
create_container
msg_ok "LXC Container Created"

# ---------- 내부 설치 ----------
msg_info "Installing Forge + SharpSharp RPG"
pct exec "$CTID" -- bash -euo pipefail -c "
apt update -qq
apt install -y openjdk-17-jre-headless wget curl unzip rsync ca-certificates >/dev/null
MC_DIR=/opt/minecraft
JAVA_BIN=/usr/bin/java
mkdir -p \$MC_DIR \$MC_DIR/backups
cd \$MC_DIR
curl -fL -o /tmp/pack.zip '${PACK_URL}'
unzip -o /tmp/pack.zip -d \$MC_DIR >/dev/null
[ -d \$MC_DIR/server ] && rsync -a \$MC_DIR/server/ \$MC_DIR/ && rm -rf \$MC_DIR/server
echo eula=true > eula.txt
if [ ! -f libraries/net/minecraftforge/forge/${FORGE_VER}/unix_args.txt ]; then
  wget -q https://maven.minecraftforge.net/net/minecraftforge/forge/${FORGE_VER}/forge-${FORGE_VER}-installer.jar
  \$JAVA_BIN -jar forge-${FORGE_VER}-installer.jar --installServer
fi
cat > user_jvm_args.txt <<EOF
-Xms4G
-Xmx8G
-XX:+UseG1GC
EOF
id minecraft &>/dev/null || useradd -r -m -s /usr/sbin/nologin minecraft
chown -R minecraft:minecraft \$MC_DIR
cat >/etc/systemd/system/minecraft.service <<EOF
[Unit]
Description=${APP}
After=network.target
[Service]
User=minecraft
WorkingDirectory=\${MC_DIR}
ExecStart=\${JAVA_BIN} @user_jvm_args.txt @libraries/net/minecraftforge/forge/${FORGE_VER}/unix_args.txt nogui
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now minecraft
cat >/usr/local/bin/mc_backup.sh <<'EOS'
#!/bin/bash
MC_DIR=/opt/minecraft
B=\$MC_DIR/backups
mkdir -p \$B
STAMP=\$(date +%F-%H%M)
systemctl stop minecraft
tar czf \$B/world-\$STAMP.tar.gz -C \$MC_DIR world server.properties 2>/dev/null || true
find \$B -type f -mtime +7 -delete
systemctl start minecraft
EOS
chmod +x /usr/local/bin/mc_backup.sh
echo '0 4 * * * root /usr/local/bin/mc_backup.sh' > /etc/cron.d/minecraft-backup
"
msg_ok "SharpSharp RPG Installed"

# ---------- 완료 ----------
post_install
msg_ok "SharpSharp RPG Forge Server Ready"
