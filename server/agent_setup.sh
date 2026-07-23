#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║         NRO GAME SERVER — AGENT BOOTSTRAP SCRIPT                ║
# ║                                                                  ║
# ║  Chạy lệnh này trên bất kỳ Replit nào có GitHub token:          ║
# ║    GH_TOKEN=ghp_xxx bash server/agent_setup.sh                  ║
# ║  hoặc:                                                           ║
# ║    bash server/agent_setup.sh ghp_xxx                           ║
# ║                                                                  ║
# ║  Script sẽ tự động:                                             ║
# ║    1. Clone repo game từ GitHub                                   ║
# ║    2. Khởi động MariaDB                                          ║
# ║    3. Restore database từ GitHub backup                          ║
# ║    4. Tải mysql-connector nếu chưa có                           ║
# ║    5. Build JAR từ source (nếu có ant)                          ║
# ║    6. Khởi động bore tunnel                                      ║
# ║    7. Khởi động Java game server                                 ║
# ║    8. Bắt đầu watchdog + backup tự động                         ║
# ║                                                                  ║
# ║  QUAN TRỌNG: Script KHÔNG thay đổi server.ip / server.port /    ║
# ║  server.external_port trong Config.properties — giữ nguyên      ║
# ║  giá trị mặc định từ repo để tránh lỗi client không kết nối.    ║
# ╚══════════════════════════════════════════════════════════════════╝

set -uo pipefail

# ──────────────────────────────────────────────────────────────────
# 0. Nhận GitHub token (env var hoặc argument)
# ──────────────────────────────────────────────────────────────────
GH_TOKEN="${GH_TOKEN:-${1:-}}"

# Nếu chưa có, thử lấy từ các secret Replit phổ biến
if [ -z "$GH_TOKEN" ]; then
  for _VAR in \
      GITHBUB_PERSONAL_ACCESS_TOKEND \
      GITHUB_PERSOJNAL_ACCESS_TOKENSJS \
      GITHUDB_PERSONAL_ACCESS_TOKENGMG \
      GITHUB_PERSOVNAL_ACCESS_TOKENBB \
      GITHUB_PERSONBAL_ACCESS_TOKENBB \
      GITHUB_PERSONAL_ACCESS_TOKEN \
      GITHUB_PERSBONAL_ACCESS_TOKENDHD \
      GITHUB_PERSJONAL_ACCESS_TOKENDJF \
      GITHUB_PERSOXNAL_ACCESS_TOKENNJC; do
    _VAL="${!_VAR:-}"
    if [ -n "$_VAL" ]; then
      GH_TOKEN="$_VAL"
      break
    fi
  done
fi

if [ -z "$GH_TOKEN" ]; then
  echo "[FAIL] Cần GitHub token!"
  echo "  Cách dùng: GH_TOKEN=ghp_xxx bash server/agent_setup.sh"
  echo "  Hoặc:      bash server/agent_setup.sh ghp_xxx"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────
# Cấu hình cố định (KHÔNG thay đổi)
# ──────────────────────────────────────────────────────────────────
REPO="kgxxyixgikcgxittixxi-collab/rem5"
GITHUB_BACKUP_PATH="db_backup/latest.sql.gz"
DB_NAME="team2026"

# Đường dẫn runtime (mất sau remix, tự khởi tạo lại)
SRC_DIR="$HOME/rem5_src"
SERVER_DIR="$HOME/nro_server"
DB_DIR="$HOME/nro_mysql"
DB_SOCK="$HOME/nro_mysql/mysql.sock"
EXTRA_CP="$HOME/nro_extra/mysql-connector-java-5.1.49.jar"
LOG_GAME="$HOME/gameserver.log"
LOG_BORE="$HOME/bore.log"
LOG_DB="$HOME/mysql.log"

# Đường dẫn trong workspace (PERSISTENT qua remix)
BORE_BIN="$HOME/workspace/server/bin/bore"
LOCAL_BACKUP="$HOME/workspace/server/db_backup/latest.sql.gz"
LOCAL_BACKUP_FAST="$HOME/workspace/server/db_backup/fast.sql.gz"

MIN_BACKUP_BYTES=5000
BACKUP_FULL_INTERVAL=300   # 5 phút
BACKUP_FAST_INTERVAL=120   # 2 phút

OK="[OK]"; FAIL="[FAIL]"; WARN="[WARN]"; INFO=">>>"
log() { echo "$(date '+%H:%M:%S') $*"; }

mkdir -p "$HOME/workspace/server/db_backup"

# ──────────────────────────────────────────────────────────────────
# Tự động tìm Java 21
# ──────────────────────────────────────────────────────────────────
find_java() {
  # Thử path đã biết trước
  local KNOWN="/nix/store/3ilfkn8kxd9f6g5hgr0wpbnhghs4mq2m-openjdk-21.0.7+6/bin/java"
  [ -x "$KNOWN" ] && { echo "$KNOWN"; return 0; }
  # Tìm bất kỳ openjdk-21 nào trong nix store
  local J
  J=$(find /nix/store -maxdepth 3 -name "java" -path "*/openjdk-21*" 2>/dev/null | head -1)
  [ -n "$J" ] && { echo "$J"; return 0; }
  # Fallback: java trong PATH
  command -v java 2>/dev/null && return 0
  return 1
}

JAVA_BIN=$(find_java) || { log "$FAIL Không tìm thấy Java 21! Cài bằng: nix-env -iA nixpkgs.jdk21"; exit 1; }
log "$INFO Java: $JAVA_BIN"

# ──────────────────────────────────────────────────────────────────
# Validate GitHub token
# ──────────────────────────────────────────────────────────────────
log "$INFO Kiểm tra GitHub token..."
GH_USER=$(curl -sf -H "Authorization: token $GH_TOKEN" \
  https://api.github.com/user | \
  node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).login||'')}catch(e){console.log('')}})" 2>/dev/null || echo "")

if [ -z "$GH_USER" ]; then
  log "$FAIL Token GitHub không hợp lệ hoặc hết hạn!"
  exit 1
fi
log "$OK Token hợp lệ (user: $GH_USER)"

# ──────────────────────────────────────────────────────────────────
# BƯỚC 1: Clone hoặc verify rem5_src
# ──────────────────────────────────────────────────────────────────
src_is_valid() {
  [ -d "$SRC_DIR/.git" ] || return 1
  [ -f "$SRC_DIR/SRC/dist/NgocRongOnline.jar" ] \
    || [ -f "$SRC_DIR/SRC/20.jar" ] \
    || [ -f "$SRC_DIR/SRC/build.xml" ] || return 1
  return 0
}

log "$INFO [1/7] Chuẩn bị source repo..."
if src_is_valid; then
  log "$OK rem5_src đã có và hợp lệ"
else
  log "  → Clone từ GitHub (CLONE_URL ẩn token)..."
  rm -rf "$SRC_DIR"
  CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
  CLONE_OK=0
  for _TRY in 1 2 3; do
    log "  → Clone lần $_TRY..."
    if GIT_TERMINAL_PROMPT=0 git clone --depth=1 "$CLONE_URL" "$SRC_DIR" 2>&1 | tail -3; then
      if src_is_valid; then
        log "$OK Clone xong"
        CLONE_OK=1
        break
      fi
      log "$WARN Clone xong nhưng thiếu file cần thiết"
    fi
    rm -rf "$SRC_DIR"
    [ $_TRY -lt 3 ] && { log "  → Thử lại sau 15s..."; sleep 15; }
  done
  [ $CLONE_OK -eq 0 ] && { log "$FAIL Clone thất bại sau 3 lần!"; exit 1; }
fi

# ──────────────────────────────────────────────────────────────────
# Đọc cấu hình server từ Config.properties trong repo
# (KHÔNG thay đổi — dùng nguyên giá trị mặc định từ repo)
# ──────────────────────────────────────────────────────────────────
CONFIG_SRC="$SRC_DIR/SRC/Config.properties"
read_cfg() {
  local KEY="$1" DEFAULT="${2:-}"
  grep -E "^\s*${KEY}\s*=" "$CONFIG_SRC" 2>/dev/null \
    | head -1 | sed 's/.*=\s*//' | tr -d '\r' || echo "$DEFAULT"
}

SERVER_IP=$(read_cfg "server.ip" "bore.pub")
SERVER_PORT=$(read_cfg "server.port" "14445")
SERVER_EXT_PORT=$(read_cfg "server.external_port" "14445")

log "$INFO Cấu hình mặc định từ repo:"
log "  server.ip           = $SERVER_IP"
log "  server.port         = $SERVER_PORT  (local game port, KHÔNG đổi)"
log "  server.external_port= $SERVER_EXT_PORT  (bore port, KHÔNG đổi)"

# ──────────────────────────────────────────────────────────────────
# BƯỚC 2: MariaDB
# ──────────────────────────────────────────────────────────────────
log "$INFO [2/7] Khởi động MariaDB..."
mkdir -p "$DB_DIR"

if [ ! -d "$DB_DIR/mysql" ]; then
  log "  → Khởi tạo DB lần đầu..."
  mysql_install_db \
    --datadir="$DB_DIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    2>&1 | tail -3
  log "$OK mysql_install_db xong"
fi

start_mysql() {
  pkill -f "mysqld.*$DB_DIR" 2>/dev/null || true
  sleep 1
  mysqld \
    --no-defaults \
    --datadir="$DB_DIR" \
    --socket="$DB_SOCK" \
    --pid-file="$DB_DIR/mysql.pid" \
    --port=3306 \
    --bind-address=127.0.0.1 \
    --skip-networking=OFF \
    --log-error="$LOG_DB" \
    --general-log=0 \
    --slow-query-log=0 \
    --skip-grant-tables \
    2>>"$LOG_DB" &
  echo $!
}

mysql_is_alive() {
  mysql --socket="$DB_SOCK" -u root -e "SELECT 1;" >/dev/null 2>&1
}

MYSQL_PID=$(start_mysql)
log "  → Chờ MySQL khởi động (PID=$MYSQL_PID)..."
for i in $(seq 1 30); do
  sleep 1
  if [ -S "$DB_SOCK" ] && mysql_is_alive; then
    log "$OK MySQL sẵn sàng (${i}s)"
    break
  fi
  if [ $i -eq 30 ]; then
    log "$FAIL MySQL không khởi động! Log:"; tail -20 "$LOG_DB" || true; exit 1
  fi
done

mysql --socket="$DB_SOCK" -u root \
  -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
  2>/dev/null || true

# ──────────────────────────────────────────────────────────────────
# BƯỚC 3: Restore database
# ──────────────────────────────────────────────────────────────────
log "$INFO [3/7] Kiểm tra database..."

verify_restore() {
  local TC
  TC=$(mysql --socket="$DB_SOCK" -u root -N \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")
  [ "${TC:-0}" -ge 5 ]
}

TABLE_COUNT=$(mysql --socket="$DB_SOCK" -u root -N \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")

if [ "${TABLE_COUNT:-0}" -ge 5 ]; then
  log "$OK Database đã có ${TABLE_COUNT} bảng, bỏ qua restore"
else
  RESTORED=0

  # Ưu tiên 1: Local workspace backup
  for _F in "$LOCAL_BACKUP" "$LOCAL_BACKUP_FAST"; do
    if [ $RESTORED -eq 0 ] && [ -f "$_F" ] \
       && [ "$(wc -c < "$_F" 2>/dev/null || echo 0)" -gt "$MIN_BACKUP_BYTES" ]; then
      log "  → Restore từ local: $_F"
      if gunzip -c "$_F" | mysql --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null \
         && verify_restore; then
        log "$OK Restored từ local backup"
        RESTORED=1
      else
        log "$WARN Local restore thất bại"
        mysql --socket="$DB_SOCK" -u root \
          -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
          2>/dev/null || true
      fi
    fi
  done

  # Ưu tiên 2: GitHub backup
  if [ $RESTORED -eq 0 ]; then
    log "  → Tải backup từ GitHub..."
    HTTP=$(curl -sf \
      -H "Authorization: token $GH_TOKEN" \
      -o /tmp/db_restore_agent.sql.gz \
      -w "%{http_code}" \
      "https://raw.githubusercontent.com/${REPO}/main/${GITHUB_BACKUP_PATH}" 2>/dev/null || echo "000")
    if [ "$HTTP" = "200" ] && [ -f /tmp/db_restore_agent.sql.gz ] \
       && [ "$(wc -c < /tmp/db_restore_agent.sql.gz 2>/dev/null || echo 0)" -gt "$MIN_BACKUP_BYTES" ]; then
      if gunzip -c /tmp/db_restore_agent.sql.gz | mysql --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null \
         && verify_restore; then
        log "$OK Restored từ GitHub backup"
        cp /tmp/db_restore_agent.sql.gz "$LOCAL_BACKUP"
        cp /tmp/db_restore_agent.sql.gz "$LOCAL_BACKUP_FAST"
        RESTORED=1
      else
        log "$WARN GitHub restore thất bại hoặc < 5 bảng"
      fi
      rm -f /tmp/db_restore_agent.sql.gz
    else
      log "$WARN Không tải được GitHub backup (HTTP $HTTP)"
    fi
  fi

  # Ưu tiên 3: SQL gốc trong repo
  if [ $RESTORED -eq 0 ]; then
    SQL_FILE="$SRC_DIR/database team2026.sql"
    if [ -f "$SQL_FILE" ]; then
      log "  → Import SQL gốc từ repo..."
      mysql --socket="$DB_SOCK" -u root "$DB_NAME" < "$SQL_FILE" \
        && log "$OK Database imported từ SQL gốc" \
        || log "$WARN Import SQL có lỗi nhỏ, tiếp tục..."
    else
      log "$WARN Không tìm thấy file SQL gốc"
    fi
  fi
fi

# ──────────────────────────────────────────────────────────────────
# BƯỚC 4: mysql-connector + server files
# ──────────────────────────────────────────────────────────────────
log "$INFO [4/7] Chuẩn bị server files..."

if [ -f "$SRC_DIR/SRC/build.xml" ] && command -v ant >/dev/null 2>&1; then
  log "  → Build JAR từ source..."
  (
    cd "$SRC_DIR/SRC"
    JAVA_HOME="$(dirname "$(dirname "$JAVA_BIN")")" \
      PATH="$(dirname "$JAVA_BIN"):$PATH" \
      ant -q clean jar
  ) && log "$OK Build JAR xong" || { log "$FAIL Build JAR thất bại!"; exit 1; }
fi

if [ ! -f "$EXTRA_CP" ] || [ "$(wc -c < "$EXTRA_CP" 2>/dev/null || echo 0)" -lt 100000 ]; then
  log "  → Download mysql-connector 5.1.49..."
  mkdir -p "$HOME/nro_extra"
  for _TRY in 1 2 3; do
    curl -sLo "$EXTRA_CP" \
      https://repo1.maven.org/maven2/mysql/mysql-connector-java/5.1.49/mysql-connector-java-5.1.49.jar \
      && [ "$(wc -c < "$EXTRA_CP" 2>/dev/null || echo 0)" -gt 100000 ] \
      && { log "$OK mysql-connector sẵn sàng"; break; } \
      || { log "$WARN Download lần $_TRY thất bại"; rm -f "$EXTRA_CP"; sleep 5; }
    [ $_TRY -eq 3 ] && { log "$FAIL Download connector thất bại!"; exit 1; }
  done
fi

mkdir -p "$SERVER_DIR"
[ -d "$SRC_DIR/SRC/lib" ] && { rm -rf "$SERVER_DIR/lib"; cp -r "$SRC_DIR/SRC/lib" "$SERVER_DIR/"; }

if [ -f "$SRC_DIR/SRC/dist/NgocRongOnline.jar" ]; then
  cp "$SRC_DIR/SRC/dist/NgocRongOnline.jar" "$SERVER_DIR/server.jar"
  log "$OK server.jar (NgocRongOnline.jar)"
elif [ -f "$SRC_DIR/SRC/20.jar" ]; then
  cp "$SRC_DIR/SRC/20.jar" "$SERVER_DIR/server.jar"
  log "$OK server.jar (20.jar)"
else
  log "$FAIL Không tìm thấy server JAR!"; exit 1
fi

[ -d "$SERVER_DIR/data" ] || cp -r "$SRC_DIR/SRC/data" "$SERVER_DIR/"

# ── Sao chép Config.properties nguyên vẹn từ repo ──
cp "$CONFIG_SRC" "$SERVER_DIR/Config.properties"

# Chỉ cập nhật phần database connection (KHÔNG đổi server.ip/port)
sed -i "s|database.host=.*|database.host=127.0.0.1|" "$SERVER_DIR/Config.properties"
sed -i "s|database.port=.*|database.port=3306|"       "$SERVER_DIR/Config.properties"
sed -i "s|database.user=.*|database.user=root|"       "$SERVER_DIR/Config.properties"
sed -i "s|database.pass=.*|database.pass=|"           "$SERVER_DIR/Config.properties"
# Xóa sv1 vì server list cũ không còn dùng
sed -i "s|server.sv1=.*|server.sv1=|"                 "$SERVER_DIR/Config.properties"

# Symlink chữ hoa → chữ thường cho data files (Linux case-sensitive)
find "$SERVER_DIR/data" -name "*[A-Z]*" 2>/dev/null | while read -r F; do
  DIR=$(dirname "$F"); BASE=$(basename "$F")
  LOWER=$(echo "$BASE" | tr '[:upper:]' '[:lower:]')
  [ "$BASE" != "$LOWER" ] && [ ! -e "$DIR/$LOWER" ] && ln -sf "$F" "$DIR/$LOWER"
done
log "$OK Server files sẵn sàng"

# ──────────────────────────────────────────────────────────────────
# BƯỚC 5: Bore tunnel
# Dùng đúng port SERVER_EXT_PORT từ Config (không thay đổi)
# ──────────────────────────────────────────────────────────────────
log "$INFO [5/7] Khởi động bore tunnel (port mặc định: $SERVER_EXT_PORT)..."

if [ ! -f "$BORE_BIN" ] || [ "$(wc -c < "$BORE_BIN" 2>/dev/null || echo 0)" -lt 100000 ]; then
  log "  → Download bore binary..."
  mkdir -p "$(dirname "$BORE_BIN")"
  curl -sLo /tmp/bore_agent.tgz \
    https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz \
    && tar -xzf /tmp/bore_agent.tgz -C "$(dirname "$BORE_BIN")/" \
    && chmod +x "$BORE_BIN" \
    || { log "$FAIL Download bore thất bại!"; exit 1; }
  rm -f /tmp/bore_agent.tgz
fi

TUNNEL_PID=""
ACTUAL_PORT=""

start_tunnel() {
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  pkill -f "bore local $SERVER_PORT" 2>/dev/null || true
  sleep 1
  ACTUAL_PORT=""

  # ── Thử đúng port mặc định từ Config trước ──
  > "$LOG_BORE"
  "$BORE_BIN" local "$SERVER_PORT" --to bore.pub --port "$SERVER_EXT_PORT" >> "$LOG_BORE" 2>&1 &
  TUNNEL_PID=$!
  for i in $(seq 1 12); do
    sleep 1
    if grep -qE 'listening at bore\.pub' "$LOG_BORE" 2>/dev/null; then
      ACTUAL_PORT="$SERVER_EXT_PORT"
      return 0
    fi
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
  done

  # Port mặc định bị chiếm → thử fallback range (vẫn ưu tiên gần nhất)
  log "$WARN bore.pub:${SERVER_EXT_PORT} bị chiếm, thử port gần nhất..."
  kill "$TUNNEL_PID" 2>/dev/null || true
  wait "$TUNNEL_PID" 2>/dev/null || true

  # Thử các port trong range SERVER_EXT_PORT+1 đến SERVER_EXT_PORT+20
  for OFF in $(seq 1 20); do
    TRY_PORT=$(( SERVER_EXT_PORT + OFF ))
    > "$LOG_BORE"
    "$BORE_BIN" local "$SERVER_PORT" --to bore.pub --port "$TRY_PORT" >> "$LOG_BORE" 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 6); do
      sleep 1
      ACTUAL_PORT=$(grep -oE 'listening at bore\.pub:[0-9]+' "$LOG_BORE" \
        | grep -oE '[0-9]+$' | tail -1 || true)
      [ -n "$ACTUAL_PORT" ] && return 0
      kill -0 "$TUNNEL_PID" 2>/dev/null || break
    done
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  done

  log "$FAIL Không tìm được cổng bore!"
  return 1
}

start_tunnel || exit 1

# Chỉ cập nhật external_port nếu bore được phân port khác (không đổi server.ip)
if [ "$ACTUAL_PORT" != "$SERVER_EXT_PORT" ]; then
  log "$WARN Port thực tế ($ACTUAL_PORT) ≠ mặc định ($SERVER_EXT_PORT)"
  log "  → Cập nhật server.external_port=$ACTUAL_PORT trong Config.properties"
  sed -i "s|server.external_port=.*|server.external_port=$ACTUAL_PORT|" "$SERVER_DIR/Config.properties"
else
  log "$OK bore.pub:$ACTUAL_PORT (đúng port mặc định)"
fi

# ──────────────────────────────────────────────────────────────────
# Ghi SERVER_PORT.txt + GitHub SERVER_IP.txt
# ──────────────────────────────────────────────────────────────────
write_server_ip() {
  local PORT="$1"
  printf 'HOST=bore.pub\nPORT=%s\nSTATUS=RUNNING\nUPDATED=%s UTC\n' \
    "$PORT" "$(date '+%Y-%m-%d %H:%M:%S')" \
    > "$HOME/workspace/server/SERVER_PORT.txt"

  # Ghi lên GitHub để APK/client biết port mới
  local CONTENT_B64
  CONTENT_B64=$(printf 'HOST=bore.pub\nPORT=%s\nSTATUS=RUNNING\nUPDATED=%s UTC\n' \
    "$PORT" "$(date '+%Y-%m-%d %H:%M:%S')" | base64 -w 0)
  local SHA
  SHA=$(curl -sf -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).sha||'')}catch(e){console.log('')}})" 2>/dev/null || echo "")
  local PAYLOAD
  [ -n "$SHA" ] \
    && PAYLOAD="{\"message\":\"[agent] bore.pub:$PORT [skip ci]\",\"content\":\"$CONTENT_B64\",\"sha\":\"$SHA\"}" \
    || PAYLOAD="{\"message\":\"[agent] bore.pub:$PORT [skip ci]\",\"content\":\"$CONTENT_B64\"}"
  curl -sf -X PUT \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    -d "$PAYLOAD" >/dev/null \
    && log "$OK SERVER_IP.txt → GitHub (bore.pub:$PORT)" \
    || log "$WARN Ghi SERVER_IP.txt thất bại"
}

# ──────────────────────────────────────────────────────────────────
# BƯỚC 6: Java game server
# ──────────────────────────────────────────────────────────────────
log "$INFO [6/7] Khởi động Java game server..."

start_java() {
  pkill -f "nro_server/server.jar" 2>/dev/null || true
  sleep 1
  > "$LOG_GAME"
  cd "$SERVER_DIR"
  "$JAVA_BIN" -server \
    -Dfile.encoding=UTF-8 \
    -Djava.net.preferIPv4Stack=true \
    -cp "${EXTRA_CP}:server.jar:lib/*" \
    nro.models.server.ServerManager \
    < /dev/null >> "$LOG_GAME" 2>&1 &
  echo $!
}

JAVA_PID=$(start_java)
sleep 8
if kill -0 "$JAVA_PID" 2>/dev/null; then
  log "$OK Java server chạy (PID=$JAVA_PID)"
else
  log "$WARN Java chưa lên, xem log:"; tail -30 "$LOG_GAME" || true
fi

# ──────────────────────────────────────────────────────────────────
# Backup functions
# ──────────────────────────────────────────────────────────────────
backup_local_fast() {
  (
    local TMP="/tmp/db_fast_$$.sql.gz"
    mysqldump --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null | gzip -1 > "$TMP"
    local SIZE; SIZE=$(wc -c < "$TMP" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt "$MIN_BACKUP_BYTES" ]; then
      mv "$TMP" "$LOCAL_BACKUP_FAST"
      cp "$LOCAL_BACKUP_FAST" "$LOCAL_BACKUP" 2>/dev/null || true
      log "$OK [fast-backup] ${SIZE} bytes → local"
    else
      rm -f "$TMP"
    fi
  ) &
}

backup_db() {
  local REASON="${1:-scheduled}"
  local TMP="/tmp/db_backup_$$.sql.gz"
  mysqldump --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null | gzip -9 > "$TMP"
  local DUMP_EXIT=${PIPESTATUS[0]}
  local SIZE; SIZE=$(wc -c < "$TMP" 2>/dev/null || echo 0)

  if [ "$DUMP_EXIT" -ne 0 ] || [ "$SIZE" -lt "$MIN_BACKUP_BYTES" ]; then
    log "$WARN [backup:$REASON] dump thất bại (exit=$DUMP_EXIT size=${SIZE}b)"
    rm -f "$TMP"; return 1
  fi

  cp "$TMP" "$LOCAL_BACKUP" && cp "$TMP" "$LOCAL_BACKUP_FAST" \
    && log "$OK [backup:$REASON] Local saved (${SIZE}b)" \
    || log "$WARN [backup:$REASON] Local save thất bại"

  if [ -n "$GH_TOKEN" ]; then
    for _TRY in 1 2 3; do
      local SHA
      SHA=$(curl -sf -H "Authorization: token $GH_TOKEN" \
        "https://api.github.com/repos/$REPO/contents/$GITHUB_BACKUP_PATH" \
        | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).sha||'')}catch(e){console.log('')}})" 2>/dev/null || echo "")
      local TS; TS=$(date '+%Y-%m-%d %H:%M UTC')
      node - <<NODEJS
const fs = require('fs');
const { execSync } = require('child_process');
const content = fs.readFileSync('${TMP}').toString('base64');
const sha = '${SHA}';
const payload = JSON.stringify({
  message: '[backup] DB ${TS} [skip ci]',
  content,
  ...(sha ? { sha } : {})
});
fs.writeFileSync('/tmp/gh_payload_$$.json', payload);
try {
  const res = execSync(
    'curl -sf -X PUT' +
    ' -H "Authorization: token ${GH_TOKEN}"' +
    ' -H "Accept: application/vnd.github+json"' +
    ' -H "Content-Type: application/json"' +
    ' "https://api.github.com/repos/${REPO}/contents/${GITHUB_BACKUP_PATH}"' +
    ' -d @/tmp/gh_payload_$$.json',
    { encoding: 'utf8', timeout: 90000 }
  );
  const json = JSON.parse(res);
  if (json.content) {
    console.log('OK sha=' + json.content.sha.slice(0,8));
    process.exit(0);
  }
  process.exit(1);
} catch(e) {
  console.error('FAIL ' + e.message);
  process.exit(1);
}
NODEJS
      if [ $? -eq 0 ]; then
        log "$OK [backup:$REASON] GitHub backup OK (lần $_TRY)"
        break
      fi
      log "$WARN [backup:$REASON] GitHub lần $_TRY thất bại"
      [ $_TRY -lt 3 ] && sleep 10
    done
  fi
  rm -f "$TMP" "/tmp/gh_payload_$$.json"
}

# ──────────────────────────────────────────────────────────────────
# SIGTERM/SIGINT trap — backup đúng thứ tự trước khi thoát
# ──────────────────────────────────────────────────────────────────
cleanup() {
  log "$WARN Tín hiệu tắt — backup khẩn cấp..."
  backup_db "shutdown"
  log "$INFO Dừng Java..."; kill "$JAVA_PID" 2>/dev/null || true; wait "$JAVA_PID" 2>/dev/null || true
  log "$INFO Dừng bore..."; kill "$TUNNEL_PID" 2>/dev/null || true
  log "$INFO Dừng MySQL..."; kill "$MYSQL_PID" 2>/dev/null || true; wait "$MYSQL_PID" 2>/dev/null || true
  log "$OK Dừng sạch."
  exit 0
}
trap cleanup SIGTERM SIGINT

# ──────────────────────────────────────────────────────────────────
# BƯỚC 7: Startup — ghi trạng thái + backup lần đầu
# ──────────────────────────────────────────────────────────────────
log "$INFO [7/7] Startup hoàn tất..."
write_server_ip "$ACTUAL_PORT"
backup_db "startup"

log ""
log "╔══════════════════════════════════════════════════════╗"
log "║          NRO SERVER ĐANG CHẠY (agent_setup v4)      ║"
log "╠══════════════════════════════════════════════════════╣"
log "║  Kết nối: bore.pub : $ACTUAL_PORT"
log "║  DB name : $DB_NAME"
log "║  Fast backup mỗi : ${BACKUP_FAST_INTERVAL}s (local)"
log "║  Full backup mỗi : ${BACKUP_FULL_INTERVAL}s (local + GitHub)"
log "║  Log game: tail -f $LOG_GAME"
log "╚══════════════════════════════════════════════════════╝"
log ""

# ──────────────────────────────────────────────────────────────────
# Watchdog loop — tự phục hồi mọi sự cố
# ──────────────────────────────────────────────────────────────────
log "$INFO Watchdog bắt đầu (check mỗi 30s)..."
BORE_FAIL=0; JAVA_FAIL=0; MYSQL_FAIL=0
LAST_FULL=$(date +%s); LAST_FAST=$(date +%s)

while true; do
  sleep 30
  NOW=$(date +%s)

  # ── Fast local backup (mỗi 2 phút, chạy ngầm) ──
  if [ $(( NOW - LAST_FAST )) -ge $BACKUP_FAST_INTERVAL ]; then
    backup_local_fast; LAST_FAST=$NOW
  fi

  # ── MySQL health check ──
  MYSQL_OK=0
  kill -0 "$MYSQL_PID" 2>/dev/null && mysql_is_alive && MYSQL_OK=1

  if [ $MYSQL_OK -eq 0 ]; then
    MYSQL_FAIL=$((MYSQL_FAIL+1))
    log "$WARN MySQL chết lần $MYSQL_FAIL! Restart..."
    MYSQL_PID=$(start_mysql)
    for _W in $(seq 1 20); do sleep 1; mysql_is_alive && break; done
    if mysql_is_alive; then
      log "$OK MySQL restarted"
      # CRITICAL: Restart Java sau MySQL (connection pool cũ không dùng được)
      log "$WARN Restart Java vì MySQL vừa restart..."
      backup_db "mysql-restart"
      JAVA_PID=$(start_java); sleep 8
      kill -0 "$JAVA_PID" 2>/dev/null \
        && log "$OK Java restarted sau MySQL" \
        || { log "$FAIL Java không lên!"; tail -20 "$LOG_GAME" || true; }
    else
      log "$FAIL MySQL vẫn không lên!"; tail -20 "$LOG_DB" || true
    fi
  fi

  # ── Bore tunnel health check ──
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    BORE_FAIL=$((BORE_FAIL+1))
    log "$WARN Tunnel chết lần $BORE_FAIL! Restart..."
    start_tunnel && {
      # Chỉ cập nhật nếu port thực tế thay đổi
      if [ "$ACTUAL_PORT" != "$SERVER_EXT_PORT" ]; then
        sed -i "s|server.external_port=.*|server.external_port=$ACTUAL_PORT|" "$SERVER_DIR/Config.properties"
      fi
      write_server_ip "$ACTUAL_PORT"
      log "$OK Tunnel mới: bore.pub:$ACTUAL_PORT"
    } || log "$FAIL Tunnel restart thất bại"
  fi

  # ── Java health check (port thực, không chỉ kill -0) ──
  JAVA_PORT_HEX=$(printf "%04X" "$SERVER_PORT")
  JAVA_PORT_OK=0
  grep -qi "$JAVA_PORT_HEX" /proc/net/tcp /proc/net/tcp6 2>/dev/null && JAVA_PORT_OK=1

  if ! kill -0 "$JAVA_PID" 2>/dev/null || [ $JAVA_PORT_OK -eq 0 ]; then
    JAVA_FAIL=$((JAVA_FAIL+1))
    if kill -0 "$JAVA_PID" 2>/dev/null && [ $JAVA_PORT_OK -eq 0 ]; then
      log "$WARN Java zombie (PID=$JAVA_PID sống nhưng port $SERVER_PORT ĐÓNG)! Kill..."
      kill -9 "$JAVA_PID" 2>/dev/null || true
      sleep 2
    fi
    log "$WARN Java lần $JAVA_FAIL! Backup + restart..."
    backup_db "java-crash"
    JAVA_PID=$(start_java)
    for _W in $(seq 1 15); do
      sleep 2
      grep -qi "$JAVA_PORT_HEX" /proc/net/tcp /proc/net/tcp6 2>/dev/null && break
    done
    grep -qi "$JAVA_PORT_HEX" /proc/net/tcp /proc/net/tcp6 2>/dev/null \
      && log "$OK Java restart OK — port $SERVER_PORT listen (PID=$JAVA_PID)" \
      || { log "$FAIL Java lên nhưng port $SERVER_PORT vẫn đóng!"; tail -20 "$LOG_GAME" || true; }
  fi

  # ── Full backup định kỳ (local + GitHub) ──
  if [ $(( NOW - LAST_FULL )) -ge $BACKUP_FULL_INTERVAL ]; then
    backup_db "scheduled"; LAST_FULL=$NOW
  fi
done
