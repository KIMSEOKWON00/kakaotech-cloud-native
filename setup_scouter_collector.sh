#!/usr/bin/env bash
# =============================================================================
# setup_scouter_collector.sh
#
# 이 스크립트를 실행하면 Scouter Collector(모니터링 서버)가
# /opt/scouter 아래에 설치되고, 바로 실행됩니다.
#
# 사용법: sudo 권한으로 아래 명령을 실행하세요.
#   sudo bash setup_scouter_collector.sh
#
# ※ Ubuntu/Debian 계열 배포판 전용이며, Java 21 JRE 기준입니다.
# =============================================================================

set -euo pipefail

# 1) 변수 설정
SCOUTER_VERSION="2.20.0"
SCOUTER_BASE="/opt/scouter"
SERVER_DIR="${SCOUTER_BASE}/server"
CONF_DIR="${SERVER_DIR}/conf"
STARTUP_SH="${SERVER_DIR}/startup.sh"

# Collector (메트릭 수신) 포트
TCP_UDP_PORT=6100

# Web UI (HTTP) 포트
HTTP_PORT=6180

echo "=== Scouter Collector 설치 시작 (버전: ${SCOUTER_VERSION}) ==="

# 2) 필수 패키지 설치 (Java 21 JRE, wget, tar)
echo "--- 2. 필수 패키지 설치 중..."
if ! command -v java >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y openjdk-21-jre-headless wget tar
else
  echo "Java가 이미 설치되어 있습니다. (버전: $(java -version 2>&1 | head -n1))"
fi

# 3) /opt/scouter 디렉터리 생성 및 권한 설정
echo "--- 3. /opt/scouter 디렉터리 생성 및 권한 설정..."
if [ ! -d "${SCOUTER_BASE}" ]; then
  mkdir -p "${SCOUTER_BASE}"
fi
chown "$(whoami):$(whoami)" "${SCOUTER_BASE}"

# 4) Scouter 바이너리 다운로드 및 압축 해제 (tar.gz 방식)
echo "--- 4. Scouter 바이너리 다운로드 및 압축 해제..."
cd "${SCOUTER_BASE}"
TAR_NAME="scouter-all-${SCOUTER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/scouter-project/scouter/releases/download/v${SCOUTER_VERSION}/${TAR_NAME}"

if [ -f "${TAR_NAME}" ]; then
  echo "  → 이미 ${TAR_NAME} 파일이 존재하므로, 다운로드를 건너뜁니다."
else
  wget -q "${DOWNLOAD_URL}"
fi

tar -xzf "${TAR_NAME}"
# 압축 해제 결과 디렉터리: scouter
mv "scouter"/* "${SCOUTER_BASE}/"
rm -rf "${TAR_NAME}" "scouter"

# 5) 서버용 scouter.conf 생성 (모든 인터페이스 수신 + HTTP 포트 포함)
echo "--- 5. Scouter 서버 설정 파일 생성 (${CONF_DIR}/scouter.conf)..."
mkdir -p "${CONF_DIR}"

cat > "${CONF_DIR}/scouter.conf" <<EOF
# ================= Scouter Collector (Server) 기본 설정 =================

# 0) 수신 IP를 명시적으로 지정 (0.0.0.0 = 모든 인터페이스)
net_collector_ip=0.0.0.0

# 1) TCP/UDP 수신 포트 (Host/Java Agent → Collector로 메트릭 전송)
net_tcp_listen_port=${TCP_UDP_PORT}
net_udp_listen_port=${TCP_UDP_PORT}

# 2) 데이터베이스/로그 디렉터리
db_dir=./database
log_dir=./logs

# 3) 디스크 사용량 90% 초과 시 오래된 데이터부터 삭제
mgr_purge_disk_usage_pct=90

# 4) 프로파일 데이터 보관 일수 (일반적으로 가장 큰 용량)
mgr_purge_profile_keep_days=30

# 5) XLog 데이터 보관 일수
mgr_purge_xlog_keep_days=30

# 6) 카운터 정보 보관 일수
mgr_purge_counter_keep_days=30

# 7) 웹 UI/HTTP 포트 (클라이언트가 대시보드 조회용)
net_http_server_port=${HTTP_PORT}

# =======================================================================
EOF

# 6) startup.sh 스크립트 생성 (백그라운드 실행 및 로그 tail)
echo "--- 6. Scouter 서버 실행용 startup.sh 생성 및 실행 권한 부여..."
mkdir -p "${SERVER_DIR}"
cat > "${STARTUP_SH}" <<'EOF'
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Scouter Collector 서버 실행 스크립트
# -----------------------------------------------------------------------------
set -euo pipefail

echo "[`date +'%Y-%m-%d %H:%M:%S'`] Scouter Collector 서버 기동을 시작합니다..."

# 1) 서버 메인 클래스 실행 (nohup 백그라운드 실행)
nohup java -Xmx1024m \
  --add-opens java.base/java.lang=ALL-UNNAMED \
  --add-opens java.base/java.util=ALL-UNNAMED \
  --add-opens java.base/sun.reflect=ALL-UNNAMED \
  --add-exports java.base/sun.misc=ALL-UNNAMED \
  --add-exports java.base/sun.net=ALL-UNNAMED \
  -Djava.security.manager=allow \
  -classpath ./scouter-server-boot.jar \
  scouter.boot.Boot ./lib \
  > nohup.out 2>&1 &

# 2) 1초 대기 후, 마지막 100줄 로그 출력
sleep 1
echo "[`date +'%Y-%m-%d %H:%M:%S'`] Scouter Collector 기동 완료. 마지막 로그:"
tail -n 100 nohup.out
EOF

chmod +x "${STARTUP_SH}"

# 7) Scouter Collector 서버 기동
echo "--- 7. Scouter Collector 서버 실행 중..."
cd "${SERVER_DIR}"
nohup bash ./startup.sh >/dev/null 2>&1

echo "=== Scouter Collector 설치 및 실행이 완료되었습니다! ==="
echo "  • 설정 파일: ${CONF_DIR}/scouter.conf"
echo "  • 실행 스크립트: ${STARTUP_SH}"
echo "  • Collector 포트 (TCP/UDP): ${TCP_UDP_PORT}"
echo "  • Web UI 포트 (HTTP) : ${HTTP_PORT}"
echo
echo "이 인스턴스는 프라이빗 서브넷에 위치하므로, OpenVPN 등을 통해"
echo "아래 주소로 Scouter 웹 UI에 접속하세요:"
PRIVATE_IP="\$(hostname -I | awk '{print \$1}')"
echo "  http://\${PRIVATE_IP}:${HTTP_PORT}"


# chmod +x setup_scouter_collector.sh (실행권한부여)
# sudo ./setup_scouter_collector.sh (sudo 권한으로 실행)
# ps aux | grep '[s]couter-server-boot.jar' (실행확인)