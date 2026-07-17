#!/data/data/com.termux/files/usr/bin/bash
# =============================================
#   Chú Bé Rồng Private Server - Termux Setup
#   by Srcnrofree / akah3674-glitch
# =============================================

RAR_ID="1uH2O2FtuGpIQfIYVAhi9wcuxfDjTQddY"
APK_ID="1pATLKSc404yUY2wO8EBiJVAvOXCdUWg2"
SERVER_DIR="$HOME/nro-chuberong"
RAR_FILE="$SERVER_DIR/server.rar"
DB_NAME="team2026"
PORT=14445
SETUP_FLAG="$SERVER_DIR/.setup_done"

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
  read -r opt
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
  echo -e "  APK mod: tải từ link đã cho hoặc $HOME/Downloads/ChuBeRong_mod.apk"
  echo ""
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
info "Bước 1/6: Cài packages..."
pkg update -y 2>/dev/null | tail -1
pkg install -y openjdk-17 mariadb unrar curl wget 2>/dev/null | tail -3
ok "Packages đã cài"

# Bước 2: Tạo thư mục
info "Bước 2/6: Tạo thư mục server..."
mkdir -p "$SERVER_DIR/lib"
mkdir -p "$HOME/Downloads"
ok "Thư mục: $SERVER_DIR"

# Bước 3: Tải RAR server
info "Bước 3/6: Tải server RAR (~629MB) - có thể mất 10-20 phút..."
DL_URL="https://drive.usercontent.google.com/download?id=${RAR_ID}&export=download&authuser=0&confirm=t"
if [ -f "$RAR_FILE" ] && [ $(stat -c%s "$RAR_FILE" 2>/dev/null || echo 0) -gt 100000000 ]; then
  ok "RAR đã tải rồi, bỏ qua"
else
  curl -L --max-redirs 15 -C - "$DL_URL" -o "$RAR_FILE" --progress-bar
  ok "Tải RAR xong: $(du -sh $RAR_FILE | cut -f1)"
fi

# Bước 4: Giải nén files cần thiết
info "Bước 4/6: Giải nén files..."
EXTRACT_DIR="/tmp/nro_extract_$$"
mkdir -p "$EXTRACT_DIR"

info "  Giải nén dist folder..."
unrar x -y "$RAR_FILE" "SRC/dist/" "$EXTRACT_DIR/" 2>/dev/null | tail -2

info "  Giải nén Config.properties..."
unrar e -y "$RAR_FILE" "Config.properties" "$EXTRACT_DIR/" 2>/dev/null | tail -1

info "  Giải nén database SQL..."
unrar e -y "$RAR_FILE" "database team2026.sql" "$EXTRACT_DIR/" 2>/dev/null | tail -1

# Copy vào server dir
if [ -f "$EXTRACT_DIR/SRC/dist/NgocRongOnline.jar" ]; then
  cp "$EXTRACT_DIR/SRC/dist/NgocRongOnline.jar" "$SERVER_DIR/"
  ok "  NgocRongOnline.jar OK"
else
  # fallback: thử extract thẳng tên file
  unrar e -y -r "$RAR_FILE" "NgocRongOnline.jar" "$SERVER_DIR/" 2>/dev/null
  ok "  NgocRongOnline.jar (fallback) OK"
fi

if [ -d "$EXTRACT_DIR/SRC/dist/lib" ]; then
  cp "$EXTRACT_DIR/SRC/dist/lib/"*.jar "$SERVER_DIR/lib/" 2>/dev/null
  ok "  Libs: $(ls $SERVER_DIR/lib/*.jar 2>/dev/null | wc -l) files"
else
  unrar e -y -r "$RAR_FILE" "*.jar" "$SERVER_DIR/lib/" 2>/dev/null
  # remove the main jar from lib if it got extracted there
  rm -f "$SERVER_DIR/lib/NgocRongOnline.jar" 2>/dev/null
fi

SQL_FILE="$SERVER_DIR/team2026.sql"
if [ -f "$EXTRACT_DIR/database team2026.sql" ]; then
  cp "$EXTRACT_DIR/database team2026.sql" "$SQL_FILE"
  ok "  SQL: $(du -sh $SQL_FILE | cut -f1)"
elif [ -f "$EXTRACT_DIR/database"*".sql" ]; then
  cp "$EXTRACT_DIR/"*".sql" "$SQL_FILE" 2>/dev/null
fi

rm -rf "$EXTRACT_DIR" 2>/dev/null

# Bước 5: Cấu hình
info "Bước 5/6: Cấu hình server..."
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

# Bước 6: Setup MariaDB
info "Bước 6/6: Setup MariaDB..."
mysql_install_db --user=root 2>/dev/null | tail -2 || true
mysqld_safe --user=root &>/dev/null &
sleep 5
ok "MariaDB khởi động"

mysql -u root 2>/dev/null << SQLEOF || true
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
FLUSH PRIVILEGES;
SQLEOF

if [ -f "$SQL_FILE" ]; then
  info "Import SQL database (~1MB)..."
  mysql -u root "$DB_NAME" < "$SQL_FILE" 2>/dev/null && ok "SQL import OK" || warn "SQL import gặp lỗi nhỏ, có thể vẫn OK"
fi

ok "MariaDB: DB '$DB_NAME' sẵn sàng"

# Tải APK về Downloads
info "Tải APK mod về Downloads..."
APK_URL="https://drive.usercontent.google.com/download?id=${APK_ID}&export=download&authuser=0&confirm=t"
APK_FILE="$HOME/Downloads/ChuBeRong_mod.apk"
curl -L --max-redirs 15 -C - "$APK_URL" -o "$APK_FILE" --progress-bar 2>/dev/null
ok "APK lưu tại: $APK_FILE"

# Start scripts
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

# Xóa RAR để tiết kiệm dung lượng
info "Xóa RAR để giải phóng bộ nhớ..."
rm -f "$RAR_FILE" 2>/dev/null

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
