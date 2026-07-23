#!/bin/bash
# ================================================
#  NRO Server - Replit Runner
#  Tự động: setup DB, bore tunnel, Java server
#  Tự restart bore + Java nếu bị chết
# ================================================

set -uo pipefail

REPO="kgxxyixgikcgxittixxi-collab/rem5"
SRC_DIR="$HOME/rem5_src"
SERVER_DIR="$HOME/nro_server"
DB_DIR="$HOME/nro_mysql"
DB_SOCK="$HOME/nro_mysql/mysql.sock"
BORE_BIN="$HOME/workspace/server/bin/bore"
JAVA_BIN="/nix/store/3ilfkn8kxd9f6g5hgr0wpbnhghs4mq2m-openjdk-21.0.7+6/bin/java"
LOG_GAME="$HOME/gameserver.log"
LOG_BORE="$HOME/bore.log"
LOG_DB="$HOME/mysql.log"

# ─── Màu log ───────────────────────────────────
OK="✅"; FAIL="❌"; WARN="⚠️ "; INFO=">>>"; ROCKET="🚀"

log() { echo "$(date '+%H:%M:%S') $*"; }

# ─── 1. Clone/Pull repo ────────────────────────
log "$INFO [1/6] Cập nhật repo từ GitHub..."
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  # Repo public: clone không cần token
  # Nếu repo private, đặt secret GITHUB_PERSONBAL_ACCESS_TOKENBB thì dùng token
  if [ -n "${GITHUB_PERSONBAL_ACCESS_TOKENBB:-}" ]; then
    CLONE_URL="https://${GITHUB_PERSONBAL_ACCESS_TOKENBB}@github.com/${REPO}.git"
  else
    CLONE_URL="https://github.com/${REPO}.git"
  fi
  git clone --depth=1 "$CLONE_URL" "$SRC_DIR" 2>&1 | tail -3
  log "$OK Clone xong"
else
  cd "$SRC_DIR"
  git pull --ff-only 2>&1 | tail -3
  log "$OK Repo đã cập nhật"
fi

# ─── 2. Khởi động MariaDB (không cần sudo) ─────
log "$INFO [2/6] Khởi động MariaDB..."
mkdir -p "$DB_DIR"

# Khởi tạo data dir lần đầu
if [ ! -d "$DB_DIR/mysql" ]; then
  log "  → Khởi tạo DB lần đầu..."
  mysql_install_db \
    --datadir="$DB_DIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    2>&1 | tail -5
  log "$OK mysql_install_db xong"
fi

# Kill mysql cũ nếu còn
pkill -f "mysqld.*$DB_DIR" 2>/dev/null || true
sleep 1

# Start mysqld
mysqld \
  --datadir="$DB_DIR" \
  --socket="$DB_SOCK" \
  --pid-file="$DB_DIR/mysql.pid" \
  --port=3306 \
  --skip-networking=0 \
  --bind-address=127.0.0.1 \
  --log-error="$LOG_DB" \
  --general-log=0 \
  --slow-query-log=0 \
  2>>"$LOG_DB" &
MYSQL_PID=$!

# Chờ MySQL sẵn sàng
log "  → Chờ MySQL khởi động..."
for i in $(seq 1 20); do
  sleep 1
  if mysqladmin --socket="$DB_SOCK" -u root ping --connect-timeout=1 >/dev/null 2>&1; then
    log "$OK MySQL sẵn sàng (${i}s)"
    break
  fi
  if [ $i -eq 20 ]; then
    log "$FAIL MySQL không khởi động được! Log:"
    tail -20 "$LOG_DB" || true
    exit 1
  fi
done

# Tạo DB và import data lần đầu
mysql --socket="$DB_SOCK" -u root \
  -e "CREATE DATABASE IF NOT EXISTS team2026 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null

TABLE_COUNT=$(mysql --socket="$DB_SOCK" -u root -N \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='team2026';" 2>/dev/null || echo "0")

if [ "$TABLE_COUNT" -lt "5" ]; then
  log "  → Import database lần đầu ($TABLE_COUNT tables)..."
  SQL_FILE="$SRC_DIR/database team2026.sql"
  if [ -f "$SQL_FILE" ]; then
    mysql --socket="$DB_SOCK" -u root team2026 < "$SQL_FILE"
    log "$OK Database imported"
  else
    log "$WARN Không tìm thấy file SQL: $SQL_FILE"
  fi
else
  log "$OK Database đã có $TABLE_COUNT bảng, bỏ qua import"
fi

# ─── 3. Chuẩn bị server files ──────────────────
log "$INFO [3/6] Chuẩn bị server files..."
mkdir -p "$SERVER_DIR/lib"

# Dùng 20.jar (fat jar) từ SRC root - giống run.bat
if [ -f "$SRC_DIR/SRC/20.jar" ]; then
  cp "$SRC_DIR/SRC/20.jar" "$SERVER_DIR/server.jar"
  log "$OK Dùng 20.jar (fat jar)"
else
  # Fallback: NgocRongOnline.jar + lib
  cp "$SRC_DIR/SRC/dist/NgocRongOnline.jar" "$SERVER_DIR/server.jar"
  cp "$SRC_DIR/SRC/dist/lib/"*.jar "$SERVER_DIR/lib/" 2>/dev/null || true
  log "$OK Dùng NgocRongOnline.jar + lib"
fi

# Copy data và config
cp -r "$SRC_DIR/SRC/data" "$SERVER_DIR/" 2>/dev/null || true
cp "$SRC_DIR/SRC/Config.properties" "$SERVER_DIR/"

# Patch Config.properties: dùng socket localhost
sed -i "s|database.host=.*|database.host=127.0.0.1|" "$SERVER_DIR/Config.properties"
sed -i "s|database.port=.*|database.port=3306|" "$SERVER_DIR/Config.properties"
sed -i "s|database.pass=.*|database.pass=|" "$SERVER_DIR/Config.properties"

# Fix case-sensitivity: tạo symlink lowercase cho file/dir viết hoa
# tile_set_Info -> tile_set_info
if [ -f "$SERVER_DIR/data/map/tile_set_Info" ] && [ ! -f "$SERVER_DIR/data/map/tile_set_info" ]; then
  ln -sf "$SERVER_DIR/data/map/tile_set_Info" "$SERVER_DIR/data/map/tile_set_info"
  log "  → Symlink: tile_set_info → tile_set_Info"
fi
# Scan toàn bộ data và tạo symlink lowercase nếu chưa có
find "$SERVER_DIR/data" -name "*[A-Z]*" | while read -r F; do
  DIR=$(dirname "$F")
  BASE=$(basename "$F")
  LOWER=$(echo "$BASE" | tr '[:upper:]' '[:lower:]')
  if [ "$BASE" != "$LOWER" ] && [ ! -e "$DIR/$LOWER" ]; then
    ln -sf "$F" "$DIR/$LOWER"
  fi
done
log "$OK Server files sẵn sàng"

# ─── 4. Tunnel: bore.pub (port cố định) ───────────────────────
log "$INFO [4/6] Khởi động tunnel bore.pub..."
LOG_BORE="$HOME/bore.log"
TUNNEL_HOST="bore.pub"
TUNNEL_PORT="20445"
TUNNEL_PID=""

if [ ! -f "$BORE_BIN" ]; then
  log "  → Download bore..."
  mkdir -p "$HOME/workspace/server/bin"
  curl -sLo /tmp/bore.tgz \
    https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz
  tar -xzf /tmp/bore.tgz -C "$HOME/workspace/server/bin/"
  chmod +x "$BORE_BIN"
fi

pkill -f "bore local 14445" 2>/dev/null || true
> "$LOG_BORE"
"$BORE_BIN" local 14445 --to bore.pub --port $TUNNEL_PORT >> "$LOG_BORE" 2>&1 &
TUNNEL_PID=$!
sleep 4
ACTUAL_PORT=$(grep -oE 'listening at bore\.pub:[0-9]+' "$LOG_BORE" | grep -oE '[0-9]+$' | tail -1 || echo "$TUNNEL_PORT")
TUNNEL_PORT=$ACTUAL_PORT
log "$OK bore.pub:$TUNNEL_PORT (port cố định)"

start_tunnel() {
  pkill -f "bore local 14445" 2>/dev/null || true
  sleep 1
  > "$LOG_BORE"
  "$BORE_BIN" local 14445 --to bore.pub --port 20445 >> "$LOG_BORE" 2>&1 &
  TUNNEL_PID=$!
  sleep 4
  NEW_PORT=$(grep -oE 'listening at bore\.pub:[0-9]+' "$LOG_BORE" | grep -oE '[0-9]+$' | tail -1 || echo "20445")
  if [ -n "$NEW_PORT" ]; then TUNNEL_PORT=$NEW_PORT; fi
}

get_tunnel_port() {
  echo "$TUNNEL_PORT"
}

# Cập nhật Config.properties với tunnel info
sed -i "s|server.ip=.*|server.ip=$TUNNEL_HOST|" "$SERVER_DIR/Config.properties"
sed -i "s|server.external_port=.*|server.external_port=$TUNNEL_PORT|" "$SERVER_DIR/Config.properties"
# Xóa sv1 tránh APK kết nối nhầm server cũ (fw.patus.tech)
sed -i "s|server.sv1=.*|server.sv1=|" "$SERVER_DIR/Config.properties"

# ─── 6. Khởi động Java server ──────────────────
log "$INFO [5/6] Khởi động Java server..."

# Đảm bảo mysql-connector 5.1.49 tồn tại (fix buildCollationMapping với MariaDB)
EXTRA_CP="$HOME/nro_extra/mysql-connector-java-5.1.49.jar"
if [ ! -f "$EXTRA_CP" ]; then
  log "  → Download mysql-connector 5.1.49..."
  mkdir -p "$HOME/nro_extra"
  curl -sLo "$EXTRA_CP" \
    https://repo1.maven.org/maven2/mysql/mysql-connector-java/5.1.49/mysql-connector-java-5.1.49.jar \
    && log "$OK mysql-connector-5.1.49 sẵn sàng" \
    || log "$WARN Download mysql-connector thất bại!"
fi

start_java() {
  pkill -f "nro_server.*server.jar" 2>/dev/null || true
  sleep 1
  > "$LOG_GAME"
  cd "$SERVER_DIR"
  # Dùng -cp thay -jar để mysql-connector 5.1.49 load trước 5.1.23 trong fat jar
  # 5.1.49 fix lỗi buildCollationMapping với MariaDB 10.x
  "$JAVA_BIN" -server -Dfile.encoding=UTF-8 \
    -Djava.net.preferIPv4Stack=true \
    -cp "${EXTRA_CP}:server.jar" \
    nro.models.server.ServerManager \
    < /dev/null \
    >> "$LOG_GAME" 2>&1 &
  echo $!
}

JAVA_PID=$(start_java)
sleep 8

if kill -0 "$JAVA_PID" 2>/dev/null; then
  log "$OK Java server đang chạy (PID=$JAVA_PID)"
else
  log "$WARN Java server chưa khởi động, xem log:"
  tail -30 "$LOG_GAME"
fi

# ─── Ghi SERVER_IP.txt vào GitHub ──────────────
update_server_ip() {
  local port=$1
  # Chỉ ghi lên GitHub nếu có token (repo private hoặc muốn cập nhật SERVER_IP.txt)
  if [ -z "${GITHUB_PERSONBAL_ACCESS_TOKENBB:-}" ]; then
    log "  → Bỏ qua ghi SERVER_IP.txt (không có token)"
    return 0
  fi
  local CONTENT_RAW="HOST=bore.pub
PORT=$port
STATUS=RUNNING
UPDATED=$(date '+%Y-%m-%d %H:%M:%S UTC')"
  local CONTENT_B64
  CONTENT_B64=$(printf '%s' "$CONTENT_RAW" | base64 -w 0)
  local SHA
  SHA=$(curl -s -H "Authorization: token ${GITHUB_PERSONBAL_ACCESS_TOKENBB}" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    | node -e "let d=''; process.stdin.on('data',c=>d+=c); process.stdin.on('end',()=>{ try{console.log(JSON.parse(d).sha||'')}catch(e){console.log('')} })")
  local PAYLOAD
  if [ -n "$SHA" ]; then
    PAYLOAD="{\"message\":\"[Replit] bore.pub:$port [skip ci]\",\"content\":\"$CONTENT_B64\",\"sha\":\"$SHA\"}"
  else
    PAYLOAD="{\"message\":\"[Replit] bore.pub:$port [skip ci]\",\"content\":\"$CONTENT_B64\"}"
  fi
  local RES
  RES=$(curl -s -X PUT \
    -H "Authorization: token ${GITHUB_PERSONBAL_ACCESS_TOKENBB}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    -d "$PAYLOAD")
  if echo "$RES" | grep -q '"content"'; then
    log "$OK SERVER_IP.txt → bore.pub:$port"
  else
    log "$WARN Ghi SERVER_IP.txt thất bại"
  fi
}

if [ -n "${TUNNEL_PORT:-}" ] && [ "$TUNNEL_PORT" != "pending" ]; then
  update_server_ip "$TUNNEL_PORT"
fi

# Luôn ghi port vào file workspace (dùng thay GitHub nếu token hết hạn)
echo "HOST=bore.pub
PORT=${TUNNEL_PORT}
UPDATED=$(date '+%Y-%m-%d %H:%M:%S')" > "$HOME/workspace/server/SERVER_PORT.txt"
log "$OK Port ghi vào server/SERVER_PORT.txt"

# ─── Hiển thị trạng thái ───────────────────────
log ""
log "======================================================"
log "  $ROCKET NRO SERVER CHẠY TRÊN REPLIT"
log "  HOST : ${TUNNEL_HOST}"
log "  PORT : ${TUNNEL_PORT}"
log "  DB   : MySQL socket $DB_SOCK"
log "  Log  : tail -f $LOG_GAME"
log "======================================================"
log ""

# ─── Monitor loop - restart bore + Java nếu chết ──
log "$INFO [6/6] Monitor loop (check mỗi 30s)..."
BORE_FAIL=0
JAVA_FAIL=0

while true; do
  sleep 30

  # Kiểm tra tunnel (serveo hoặc bore)
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    BORE_FAIL=$((BORE_FAIL+1))
    log "$WARN Tunnel chết lần $BORE_FAIL! Restart..."
    start_tunnel
    sleep 10
    NEW_PORT=$(get_tunnel_port)
    if [ -n "$NEW_PORT" ]; then
      TUNNEL_PORT=$NEW_PORT
      log "$OK Tunnel port mới: $TUNNEL_HOST:$TUNNEL_PORT"
      sed -i "s|server.external_port=.*|server.external_port=$TUNNEL_PORT|" "$SERVER_DIR/Config.properties"
      update_server_ip "$TUNNEL_PORT"
      echo "HOST=bore.pub
PORT=${TUNNEL_PORT}
UPDATED=$(date '+%Y-%m-%d %H:%M:%S')" > "$HOME/workspace/server/SERVER_PORT.txt"
    fi
  fi

  # Kiểm tra Java
  if ! kill -0 "$JAVA_PID" 2>/dev/null; then
    JAVA_FAIL=$((JAVA_FAIL+1))
    log "$WARN Java server chết lần $JAVA_FAIL! Restart..."
    JAVA_PID=$(start_java)
    sleep 6
    if kill -0 "$JAVA_PID" 2>/dev/null; then
      log "$OK Java server restart OK (PID=$JAVA_PID)"
    else
      log "$FAIL Java vẫn không lên! Log 20 dòng cuối:"
      tail -20 "$LOG_GAME" || true
    fi
  fi

  # Kiểm tra MySQL
  if ! kill -0 "$MYSQL_PID" 2>/dev/null; then
    log "$WARN MySQL chết! Restart..."
    mysqld \
      --datadir="$DB_DIR" \
      --socket="$DB_SOCK" \
      --pid-file="$DB_DIR/mysql.pid" \
      --port=3306 \
      --skip-networking=0 \
      --bind-address=127.0.0.1 \
      --log-error="$LOG_DB" \
      2>>"$LOG_DB" &
    MYSQL_PID=$!
    sleep 5
    log "$OK MySQL restarted"
  fi
done
