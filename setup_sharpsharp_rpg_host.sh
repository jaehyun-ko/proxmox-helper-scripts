#!/usr/bin/env bash
# =============================================================================
# Title   : SharpSharp RPG Forge Server (Proxmox Helper)
# Author  : jaehyun-ko
# License : MIT
# =============================================================================
set -euo pipefail
trap 'echo "[ERR] 실패 (line:$LINENO)" >&2' ERR

# 기본 정보
APP="SharpSharp RPG Forge Server"
CTID=120
HOSTNAME="sharpsharp-rpg"
DISK_SIZE="40G"
CORES=4
MEMORY=8192
BRIDGE="vmbr0"
TEMPLATE="local:vztmpl/debian-12-standard_12.5-1_amd64.tar.zst"

FORGE_VER="1.20.1-47.4.0"
PACK_URL="https://mediafilez.forgecdn.net/files/6861/683/%5BSTANDARD%5D%20SharpSharp%20RPG%20Release%201.4.1.zip"

echo "⚙️  Proxmox Helper - ${APP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ---------------------------------------------------------------------------
# 1. 컨테이너 생성
# ---------------------------------------------------------------------------
if pct status "$CTID" &>/dev/null; then
  echo "⚠️  CTID $CTID 이미 존재합니다. 종료합니다."
  exit 1
fi

echo "🧱  Debian 12 LXC 생성..."
pct create "$CTID" "$TEMPLATE" \
  -hostname "$HOSTNAME" \
  -cores "$CORES" \
  -memory "$MEMORY" \
  -rootfs "local-lvm:${DISK_SIZE}" \
  -net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  -features nesting=1 \
  -unprivileged 0 \
  -password "minecraft"

pct start "$CTID"
sleep 10

# ---------------------------------------------------------------------------
# 2. 내부 설치 실행
# ---------------------------------------------------------------------------
echo "🚀  컨테이너 내부 설치 중..."
pct exec "$CTID" -- bash -euo pipefail -c "
apt update -qq && apt install -y openjdk-17-jre-headless wget curl unzip rsync ca-certificates >/dev/null

MC_DIR=/opt/minecraft
JAVA_BIN=/usr/bin/java
FORGE_VER='${FORGE_VER}'
PACK_URL='${PACK_URL}'
mkdir -p \$MC_DIR \$MC_DIR/backups
cd \$MC_DIR

curl -fL -o /tmp/sharpsharp.zip \$PACK_URL
unzip -o /tmp/sharpsharp.zip -d \$MC_DIR >/dev/null
[ -d \$MC_DIR/server ] && rsync -a \$MC_DIR/server/ \$MC_DIR/ && rm -rf \$MC_DIR/server

echo 'eula=true' > \$MC_DIR/eula.txt
if [ ! -f \$MC_DIR/libraries/net/minecraftforge/forge/\${FORGE_VER}/unix_args.txt ]; then
  wget -q https://maven.minecraftforge.net/net/minecraftforge/forge/\${FORGE_VER}/forge-\${FORGE_VER}-installer.jar
  \$JAVA_BIN -jar forge-\${FORGE_VER}-installer.jar --installServer
fi

cat > \$MC_DIR/user_jvm_args.txt <<EOF
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
ExecStart=\${JAVA_BIN} @user_jvm_args.txt @libraries/net/minecraftforge/forge/\${FORGE_VER}/unix_args.txt nogui
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minecraft

cat >/usr/local/bin/mc_backup.sh <<'EOS'
#!/bin/bash
set -euo pipefail
MC_DIR="/opt/minecraft"
BACKUP_DIR="\${MC_DIR}/backups"
STAMP=\$(date +%F-%H%M)
mkdir -p "\${BACKUP_DIR}"
systemctl stop minecraft
tar czf "\${BACKUP_DIR}/world-\${STAMP}.tar.gz" -C "\${MC_DIR}" world
find "\${BACKUP_DIR}" -type f -mtime +7 -delete
systemctl start minecraft
EOS
chmod +x /usr/local/bin/mc_backup.sh
echo '0 4 * * * root /usr/local/bin/mc_backup.sh' > /etc/cron.d/minecraft-backup
"

# ---------------------------------------------------------------------------
# 3. 결과 요약
# ---------------------------------------------------------------------------
echo
echo "✅ 설치 완료!"
echo "   컨테이너 ID : $CTID"
echo "   접근        : pct enter $CTID"
echo "   경로        : /opt/minecraft"
echo "   서비스      : systemctl status minecraft"
echo "   백업        : /usr/local/bin/mc_backup.sh (매일 04:00, 7일 보관)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
