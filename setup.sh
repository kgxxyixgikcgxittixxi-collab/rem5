#!/data/data/com.termux/files/usr/bin/bash
# =============================================
#   Chú Bé Rồng Private Server - Termux Setup
#   by Srcnrofree / akah3674-glitch
# =============================================

APK_ID="1pATLKSc404yUY2wO8EBiJVAvOXCdUWg2"
SERVER_DIR="$HOME/nro-chuberong"
DB_NAME="team2026"
PORT=14445
SETUP_FLAG="$SERVER_DIR/.setup_done"
GH_RAW="https://raw.githubusercontent.com/akah3674-glitch/rem5/main/server"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()     { echo -e "${RED}[ERR]${NC} $1"; }

get_local_ip() {
  ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1
}

show_menu() {
  LOCAL_IP=$(get_local_ip)
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║    CHÚ BÉ RỒNG PRIVATE SERVER        ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  echo -e "  IP server: ${GREEN}$LOCAL_IP${NC}"
  echo -e "  Port game: ${GREEN}$PORT${NC}"
  echo -e "  DB: ${GREEN}$DB_NAME${NC}"
  echo ""
  echo "  1. Khởi động server"
  echo "  2. Dừng server"
  echo "  3. Xem trạng thái"
  echo "  4. Xem log"
  echo "  5. Khởi động lại"
  echo "  6. Thông tin kết nối (nhập vào game)"
  echo "  0. Thoát"
  echo ""
  printf "  Chọn: "
  read -r opt </dev/tty
  case "$opt" in
    1) start_server ;;
    2) stop_server ;;
    3) status_server ;;
    4) tail -100 "$SERVER_DIR/server.log" 2>/dev/null || warn "Chưa có log" ;;
    5) stop_server; sleep 2; start_server ;;
    6) show_connect_info ;;
    0) exit 0 ;;
    *) warn "Không hợp lệ" ;;
  esac
  show_menu
}

start_server() {
  if pgrep -f "NgocRongOnline.jar" > /dev/null; then
    warn "Server đang chạy rồi"
    return
  fi
  info "Khởi động MariaDB..."
  mysqld_safe --user=root &>/dev/null &
  sleep 3
  info "Khởi động game server..."
  cd "$SERVER_DIR"
  nohup java -jar NgocRongOnline.jar > "$SERVER_DIR/server.log" 2>&1 &
  echo $! > "$SERVER_DIR/server.pid"
  sleep 3
  if pgrep -f "NgocRongOnline.jar" > /dev/null; then
    ok "Server đã khởi động! PID: $(cat $SERVER_DIR/server.pid)"
  else
    err "Server không khởi động được - kiểm tra log: tail -50 $SERVER_DIR/server.log"
  fi
}

stop_server() {
  if [ -f "$SERVER_DIR/server.pid" ]; then
    kill $(cat "$SERVER_DIR/server.pid") 2>/dev/null
    rm -f "$SERVER_DIR/server.pid"
  fi
  pkill -f "NgocRongOnline.jar" 2>/dev/null
  ok "Đã dừng server"
}

status_server() {
  if pgrep -f "NgocRongOnline.jar" > /dev/null; then
    ok "Server đang chạy | PID: $(pgrep -f NgocRongOnline.jar)"
  else
    warn "Server không chạy"
  fi
  if mysqladmin -u root ping 2>/dev/null | grep -q alive; then
    ok "MariaDB đang chạy"
  else
    warn "MariaDB không chạy"
  fi
}

show_connect_info() {
  LOCAL_IP=$(get_local_ip)
  echo ""
  echo -e "${GREEN}=== THÔNG TIN KẾT NỐI GAME ===${NC}"
  echo -e "  Trong game → Nhập IP và PORT:"
  echo -e "  IP Game  : ${YELLOW}$LOCAL_IP${NC}"
  echo -e "  PORT Game: ${YELLOW}$PORT${NC}"
  echo ""
  echo -e "  APK mod: $HOME/Downloads/ChuBeRong_mod.apk"
  echo ""
}

dl() {
  # dl <url> <dest>
  curl -fsSL --max-redirs 10 --retry 3 -o "$2" "$1"
}

# ─── Nếu đã setup xong → vào menu ─────────────────
if [ -f "$SETUP_FLAG" ]; then
  show_menu
  exit 0
fi

# ─── LẦN ĐẦU: SETUP ───────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  SETUP CHÚ BÉ RỒNG PRIVATE SERVER   ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# Bước 1: Cài packages
info "Bước 1/5: Cài packages..."
pkg update -y 2>/dev/null | tail -1
pkg install -y openjdk-17 mariadb curl wget 2>/dev/null | tail -3
ok "Packages đã cài (không cần unrar nữa)"

# Bước 2: Tạo thư mục
info "Bước 2/5: Tạo thư mục server..."
mkdir -p "$SERVER_DIR/lib"
mkdir -p "$HOME/Downloads"
ok "Thư mục: $SERVER_DIR"

# Bước 3: Tải file server từ GitHub
info "Bước 3/5: Tải server files từ GitHub (~8MB)..."

info "  NgocRongOnline.jar..."
dl "$GH_RAW/NgocRongOnline.jar" "$SERVER_DIR/NgocRongOnline.jar"
ok "  NgocRongOnline.jar ($(du -sh $SERVER_DIR/NgocRongOnline.jar | cut -f1))"

info "  Thư viện (lib)..."
LIBS=(
  apache-commons-lang.jar
  bson-5.1.3.jar
  gson-2.8.2.jar
  HikariCP-5.1.0.jar
  java-json.jar
  json-simple-1.1.jar
  log4j-1.2.17.jar
  lombok.jar
  mysql-connector-java-5.1.49.jar
  slf4j-api-2.0.0-alpha1.jar
  slf4j-simple-2.0.0-alpha1.jar
)
for lib in "${LIBS[@]}"; do
  dl "$GH_RAW/lib/$lib" "$SERVER_DIR/lib/$lib"
done
ok "  Libs: $(ls $SERVER_DIR/lib/*.jar | wc -l) files"

info "  Database SQL..."
dl "$GH_RAW/database_team2026.sql" "$SERVER_DIR/team2026.sql"
ok "  SQL: $(du -sh $SERVER_DIR/team2026.sql | cut -f1)"

# Bước 4: Cấu hình
info "Bước 4/5: Cấu hình server..."
LOCAL_IP=$(get_local_ip)
warn "IP tự động phát hiện: $LOCAL_IP"

cat > "$SERVER_DIR/Config.properties" << EOF
#SERVER
server.local=false
server.test=false
server.daoautoupdater=false
server.sv=1
server.name=Chu Be Rong Private
server.ip=$LOCAL_IP
server.port=$PORT
server.sv1=
server.waitlogin=3
server.maxperip=999
server.maxplayer=1000
server.expserver=3

#DATABASE
database.driver=com.mysql.jdbc.Driver
database.host=localhost
database.port=3306
database.name=$DB_NAME
database.user=root
database.pass=
database.min=1
database.max=5
database.lifetime=120000
EOF
ok "Config.properties đã tạo với IP: $LOCAL_IP"

# Bước 5: Setup MariaDB
info "Bước 5/5: Setup MariaDB..."
mysql_install_db --user=root 2>/dev/null | tail -2 || true
mysqld_safe --user=root &>/dev/null &
sleep 5
ok "MariaDB khởi động"

mysql -u root 2>/dev/null << SQLEOF || true
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
FLUSH PRIVILEGES;
SQLEOF

info "Import SQL database (~1MB)..."
mysql -u root "$DB_NAME" < "$SERVER_DIR/team2026.sql" 2>/dev/null \
  && ok "SQL import OK" \
  || warn "SQL import gặp lỗi nhỏ, có thể vẫn OK"

ok "MariaDB: DB '$DB_NAME' sẵn sàng"

# Tải APK
info "Tải APK mod về Downloads (~84MB)..."
APK_URL="https://drive.usercontent.google.com/download?id=${APK_ID}&export=download&authuser=0&confirm=t"
APK_FILE="$HOME/Downloads/ChuBeRong_mod.apk"
curl -L --max-redirs 15 -C - "$APK_URL" -o "$APK_FILE" --progress-bar 2>/dev/null
ok "APK lưu tại: $APK_FILE"

# Start/Stop scripts
cat > "$SERVER_DIR/start.sh" << 'STARTEOF'
#!/data/data/com.termux/files/usr/bin/bash
cd ~/nro-chuberong
mysqld_safe --user=root &>/dev/null &
sleep 4
nohup java -jar NgocRongOnline.jar > ~/nro-chuberong/server.log 2>&1 &
echo $! > ~/nro-chuberong/server.pid
echo "[OK] Server khởi động! PID: $(cat ~/nro-chuberong/server.pid)"
echo "[INFO] Xem log: tail -f ~/nro-chuberong/server.log"
STARTEOF

cat > "$SERVER_DIR/stop.sh" << 'STOPEOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -f "NgocRongOnline.jar"
rm -f ~/nro-chuberong/server.pid
echo "[OK] Đã dừng server"
STOPEOF

chmod +x "$SERVER_DIR/start.sh" "$SERVER_DIR/stop.sh"

# Đánh dấu setup xong
touch "$SETUP_FLAG"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         SETUP HOÀN TẤT! ✓            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  IP server: ${YELLOW}$LOCAL_IP${NC}  |  Port: ${YELLOW}$PORT${NC}"
echo ""
echo -e "  Khởi động server: ${CYAN}bash ~/nro-chuberong/start.sh${NC}"
echo -e "  Hoặc chạy lại script để vào menu:"
echo -e "  ${CYAN}curl -fsSL https://raw.githubusercontent.com/akah3674-glitch/rem5/main/setup.sh | bash${NC}"
echo ""
echo -e "  Trong game → Nhập IP: ${YELLOW}$LOCAL_IP${NC}  Port: ${YELLOW}$PORT${NC}"
echo ""

start_server
