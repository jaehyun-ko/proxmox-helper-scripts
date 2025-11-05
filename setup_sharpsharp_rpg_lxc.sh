#!/bin/bash
set -euo pipefail

FORGE_VER="1.20.1-47.4.0"
MC_DIR="/opt/minecraft"
JAVA_BIN="/usr/bin/java"
SERVER_PACK_URL="https://mediafilez.forgecdn.net/files/6861/683/%5BSTANDARD%5D%20SharpSharp%20RPG%20Release%201.4.1.zip"

echo "[+] Updating and installing dependencies..."
apt update -y && apt install -y openjdk-17-jre-headless wget curl unzip rsync screen ca-certificates

mkdir -p "${MC_DIR}"
cd "${MC_DIR}"

echo "[+] Downloading SharpSharp RPG server pack..."
curl -L -o /tmp/sharpsharp.zip "${SERVER_PACK_URL}"

echo "[+] Unpacking..."
unzip -o /tmp/sharpsharp.zip -d "${MC_DIR}"

# 일부 패키지는 내부 폴더가 한 겹 더 있음
if [ -d "${MC_DIR}/server" ]; then
  rsync -a "${MC_DIR}/server/" "${MC_DIR}/"
  rm -rf "${MC_DIR}/server"
fi

echo "[+] Accepting EULA..."
echo "eula=true" > "${MC_DIR}/eula.txt"

# Forge 설치 확인
if [ ! -f "${MC_DIR}/libraries/net/minecraftforge/forge/${FORGE_VER}/unix_args.txt" ]; then
  echo "[+] Installing Forge ${FORGE_VER}..."
  wget -q "https://maven.minecraftforge.net/net/minecraftforge/forge/${FORGE_VER}/forge-${FORGE_VER}-installer.jar"
  "${JAVA_BIN}" -jar "forge-${FORGE_VER}-installer.jar" --installServer
fi

# 기본 JVM 메모리 설정
cat > "${MC_DIR}/user_jvm_args.txt" <<EOF
-Xms4G
-Xmx8G
EOF

chmod +x "${MC_DIR}/run.sh" || true

echo "[+] Creating systemd service..."
cat >/etc/systemd/system/minecraft.service <<EOF
[Unit]
Description=SharpSharp RPG Forge Server
After=network.target

[Service]
WorkingDirectory=${MC_DIR}
ExecStart=${JAVA_BIN} @user_jvm_args.txt @libraries/net/minecraftforge/forge/${FORGE_VER}/unix_args.txt nogui
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minecraft

echo
echo "[✓] SharpSharp RPG Forge 서버 설치 완료!"
echo "경로: ${MC_DIR}"
echo "로그: ${MC_DIR}/logs/latest.log"
echo "관리 명령:"
echo "  systemctl restart minecraft   # 재시작"
echo "  systemctl stop minecraft      # 중지"
echo "  tail -f ${MC_DIR}/logs/latest.log"
echo
