#!/usr/bin/env bash
# =============================================================================
# Title   : SharpSharp RPG Forge Server (Proxmox Helper)
# Author  : jaehyun-ko
# License : MIT
# =============================================================================
set -euo pipefail
trap 'echo "[ERR] 실패 (line:$LINENO)" >&2; exit 1' ERR

# ----- 사용자 변수(환경변수로도 오버라이드 가능) -----------------------------
APP="${APP:-SharpSharp RPG Forge Server}"
CTID="${CTID:-120}"
HOSTNAME="${HOSTNAME:-sharpsharp-rpg}"
DISK_SIZE="${DISK_SIZE:-40G}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-local}"   # rootdir 컨텐츠 가능한 스토리지 ID
TEMPLATE_FILE="${TEMPLATE_FILE:-debian-12-standard_12.12-1_amd64.tar.zst}"
TEMPLATE="${TEMPLATE:-${STORAGE}:vztmpl/${TEMPLATE_FILE}}"

FORGE_VER="${FORGE_VER:-1.20.1-47.4.0}"
PACK_URL="${PACK_URL:-https://mediafilez.forgecdn.net/files/6861/683/%5BSTANDARD%5D%20SharpSharp%20RPG%20Release%201.4.1.zip}"

echo "⚙️  Proxmox Helper - ${APP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ----- 사전 검증: 스토리지/템플릿 -------------------------------------------
# STORAGE 유효성
if ! pvesm status | awk 'NR>1{print $1}' | grep -qx "$STORAGE"; then
  echo "[ERR] 스토리지 '$STORAGE' 를 찾을 수 없음. 'pvesm status'로 ID 확인 후 STORAGE 변경."
  exit 1
fi

# 템플릿 파일 존재 확인 및 자동 다운로드
TPL_CACHE="/var/lib/vz/template/cache/${TEMPLATE_FILE}"
if [[ ! -f "$TPL_CACHE" ]]; then
  echo "📦 템플릿 다운로드: ${TEMPLATE_FILE} → ${STORAGE}"
  pveam update
  pveam download "$STORAGE" "$TEMPLATE_FILE"
fi

# 컨테이너 ID 중복
if pct status "$CTID" &>/dev/null; then
  echo "⚠️  CTID $CTID 이미 존재합니다. 종료합니다."
  exit 1
fi

# ----- 1) 컨테이너 생성 ------------------------------------------------------
echo "🧱  Debian 12 LXC 생성..."
pct create "$CTID" "$TEMPLATE" \
  -hostname "$HOSTNAME" \
  -cores "$CORES" \
  -memory "$MEMORY" \
  -rootfs "${STORAGE}:${DISK_SIZE}" \
  -net0 name=eth0,bridge="$BRIDGE",ip=dhcp \
  -features nesting=1 \
  -unprivileged 0 \
  -password "minecraft"

pct start "$CTID"
sleep 8

# ----- 2) 내부 설치 ----------------------------------------------------------
echo "🚀  컨테이너 내부 설치 중..."
pct exec "$CTID" -- bash -euo pipefail -c "
export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y openjdk-17-jre-headless wget curl unzip rsync ca-certificates >/dev/null

MC_DIR=/opt/minecraft
JAVA_BIN=/usr/bin/java
FORGE_VER='${FORGE_VER}'
PACK_URL='${PACK_URL}'

mkdir -p \"\$MC_DIR\" \"\$MC_DIR/backups\"
cd \"\$MC_DIR\"

echo '[+] 서버팩 다운로드'
curl -fL --retry 3 --retry-delay 2 -o /tmp/sharpsharp.zip \"\$PACK_URL\"
unzip -t /tmp/sharpsharp.zip >/dev/null
unzip -o /tmp/sharpsharp.zip -d \"\$MC_DIR\" >/dev/null

# 일부 배포는 최상위에 server/ 폴더가 있음 → 평탄화
[ -d \"\$MC_DIR/server\" ] && rsync -a \"\$MC_DIR/server/\" \"\$MC_DIR/\" && rm -rf \"\$MC_DIR/server\"

echo 'eula=true' > \"\$MC_DIR/eula.txt\"

echo '[+] Forge 설치 확인'
if [ ! -f \"\$MC_DIR/libraries/net/minecraftforge/forge/\${FORGE_VER}/unix_args.txt\" ]; then
  curl -fL --retry 3 --retry-delay 2 -o \"\$MC_DIR/forge-\${FORGE_VER}-installer.jar\" \
    \"https://maven.minecraftforge.net/net/minecraftforge/forge/\${FORGE_VER}/forge-\${FORGE_VER}-installer.jar\"
  \"\$JAVA_BIN\" -jar \"forge-\${FORGE_VER}-installer.jar\" --installServer
fi

# JVM 기본값
cat > \"\$MC_DIR/user_jvm_args.txt\" <<EOF
-Xms4G
-Xmx8G
-XX:+UseG1GC
-XX:MaxGCPauseMillis=100
EOF

chmod +x \"\$MC_DIR/run.sh\" || true

# 실행계정
id minecraft &>/dev/null || useradd -r -m -s /usr/sbin/nologin minecraft
chown -R minecraft:minecraft \"\$MC_DIR\"

# systemd 서비스 (@args 방식)
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

# 백업 스크립트(서비스 일시 정지 → 압축 → 7일 보관)
cat >/usr/local/bin/mc_backup.sh <<'EOS'
#!/bin/bash
set -euo pipefail
MC_DIR="/opt/minecraft"
BACKUP_DIR="${MC_DIR}/backups"
STAMP=$(date +%F-%H%M)
mkdir -p "${BACKUP_DIR}"
systemctl stop minecraft
tar czf "${BACKUP_DIR}/world-${STAMP}.tar.gz" -C "${MC_DIR}" world server.properties 2>/dev/null || true
find "${BACKUP_DIR}" -type f -mtime +7 -delete
systemctl start minecraft
EOS
chmod +x /usr/local/bin/mc_backup.sh
echo '0 4 * * * root /usr/local/bin/mc_backup.sh' > /etc/cron.d/minecraft-backup
chmod 644 /etc/cron.d/minecraft-backup

# 로그 로테이션(일 1회, 7일 보관)
cat >/etc/logrotate.d/minecraft <<'EOF'
/opt/minecraft/logs/*.log {
  daily
  rotate 7
  compress
  missingok
  notifempty
}
EOF
"

# ----- 3) 결과 요약 ----------------------------------------------------------
echo
echo "✅ 설치 완료!"
echo "   컨테이너 ID : $CTID"
echo "   접근        : pct enter $CTID"
echo "   경로        : /opt/minecraft"
echo "   서비스      : systemctl status minecraft"
echo "   백업        : /usr/local/bin/mc_backup.sh (매일 04:00, 7일 보관)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
