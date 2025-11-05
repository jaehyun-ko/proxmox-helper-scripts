#!/bin/bash
# ============================================================================
# Proxmox Helper Script : SharpSharp RPG Forge Server (LXC 자동 구축 + 백업)
# Author  : jaehyun-ko
# Version : 2025-11-05
# Target  : Proxmox VE 8.x (Host root shell)
# ============================================================================
# 기능:
# 1) Debian 12 LXC 생성
# 2) Forge 1.20.1-47.4.0 + SharpSharp RPG 1.4.1 설치
# 3) systemd 서비스 등록(자동 시작)
# 4) 매일 04:00 월드 백업(서비스 중지→압축→재기동, 7일 보관)
# ============================================================================

set -euo pipefail
trap 'echo "[ERR] 실패 (line:$LINENO)" >&2; exit 1' ERR

# ===== 사용자 변수 =====
CTID=120
HOSTNAME="sharpsharp-rpg"
TEMPLATE="local:vztmpl/debian-12-standard_12.5-1_amd64.tar.zst"
STORAGE="local-lvm"
DISK_SIZE="40G"
CORES=4
MEMORY=8192                                 # MB
BRIDGE="vmbr0"
IP="dhcp"                                   # 예: "192.168.1.150/24,gw=192.168.1.1"
SSH_PUBKEY="/root/.ssh/id_rsa.pub"          # 없으면 무시

FORGE_VER="1.20.1-47.4.0"
PACK_URL="https://mediafilez.forgecdn.net/files/6861/683/%5BSTANDARD%5D%20SharpSharp%20RPG%20Release%201.4.1.zip"

# ===== LXC 생성 =====
echo "=== [1/5] LXC 생성 ==="
if pct status "$CTID" &>/dev/null; then
  echo "[WARN] CTID $CTID 이미 존재. 종료."
  exit 1
fi

pct create "$CTID" "$TEMPLATE" \
  -hostname "$HOSTNAME" \
  -cores "$CORES" \
  -memory "$MEMORY" \
  -rootfs "${STORAGE}:${DISK_SIZE}" \
  -net0 name=eth0,bridge="${BRIDGE}",ip="${IP}" \
  -features nesting=1 \
  -unprivileged 0 \
  -password "minecraft" \
  ${SSH_PUBKEY:+-ssh-public-keys "$SSH_PUBKEY"}

pct start "$CTID"
sleep 10

# ===== 내부 설치 =====
echo "=== [2/5] Forge + SharpSharp RPG 설치 ==="
pct exec "$CTID" -- bash -euo pipefail -c "
  set -euo pipefail

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

  # 상위 폴더 평탄화
  [ -d \"\$MC_DIR/server\" ] && rsync -a \"\$MC_DIR/server/\" \"\$MC_DIR/\" && rm -rf \"\$MC_DIR/server\"

  echo 'eula=true' > \"\$MC_DIR/eula.txt\"

  echo '[+] Forge 설치 확인'
  if [ ! -f \"\$MC_DIR/libraries/net/minecraftforge/forge/\${FORGE_VER}/unix_args.txt\" ]; then
    wget -q \"https://maven.minecraftforge.net/net/minecraftforge/forge/\${FORGE_VER}/forge-\${FORGE_VER}-installer.jar\"
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

  # 실행 계정
  id minecraft &>/dev/null || useradd -r -m -s /usr/sbin/nologin minecraft
  chown -R minecraft:minecraft \"\$MC_DIR\"

  # systemd 서비스 (@args 방식 그대로)
  cat >/etc/systemd/system/minecraft.service <<EOF
[Unit]
Description=SharpSharp RPG Forge Server
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

  # ===== 백업 스크립트(서비스 잠깐 중지 방식: 데이터 일관성 보장) =====
  cat >/usr/local/bin/mc_backup.sh <<'EOS'
#!/bin/bash
set -euo pipefail
MC_DIR="/opt/minecraft"
BACKUP_DIR="${MC_DIR}/backups"
STAMP=$(date +%F-%H%M)

mkdir -p "${BACKUP_DIR}"

echo "[backup] stop server"
systemctl stop minecraft

# 백업 대상 최소화: world + 핵심 설정
cd "${MC_DIR}"
tar czf "${BACKUP_DIR}/world-${STAMP}.tar.gz" \
  world server.properties \
  whitelist.json 2>/dev/null || true
# whitelist.json 없을 수 있음 → 오류 무시

# 7일 보관
find "${BACKUP_DIR}" -type f -mtime +7 -delete

echo "[backup] start server"
systemctl start minecraft
echo "[backup] done: ${BACKUP_DIR}/world-${STAMP}.tar.gz"
EOS
  chmod +x /usr/local/bin/mc_backup.sh

  # 매일 04:00 백업 크론 등록
  echo '0 4 * * * root /usr/local/bin/mc_backup.sh' > /etc/cron.d/minecraft-backup
  chmod 644 /etc/cron.d/minecraft-backup
"

# ===== 상태/요약 =====
echo "=== [3/5] 서비스 상태 ==="
pct exec "$CTID" -- systemctl status minecraft --no-pager | head -n 15 || true

echo "=== [4/5] 포트 확인(초기 로딩 중이면 미표시) ==="
pct exec "$CTID" -- ss -tlnp | grep 25565 || true

echo "=== [5/5] 요약 ==="
cat <<EOF

[✓] SharpSharp RPG Forge 서버 구축 완료
------------------------------------------------------------
컨테이너 ID : $CTID
호스트 이름 : $HOSTNAME
OS 템플릿   : Debian 12
서버 경로   : /opt/minecraft
실행 계정   : minecraft
포트        : 25565/TCP
로그 보기   : pct exec $CTID -- tail -f /opt/minecraft/logs/latest.log
콘솔 진입   : pct enter $CTID
백업 스크립트: /usr/local/bin/mc_backup.sh (매일 04:00, 7일 보관)
수동 백업    : pct exec $CTID -- /usr/local/bin/mc_backup.sh
복원(월드만) : systemctl stop minecraft; tar xzf /opt/minecraft/backups/world-YYYY-MM-DD-HHMM.tar.gz -C /opt/minecraft; systemctl start minecraft
------------------------------------------------------------
EOF
