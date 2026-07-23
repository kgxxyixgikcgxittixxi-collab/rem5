#!/bin/bash
# ================================================
#  NRO Game Server - Replit Runner
#  - Chạy hoàn toàn trên Replit (không cần GitHub Actions)
#  - Tự clone rem5_src nếu chưa có (remix mới)
#  - Tự restore DB từ backup GitHub nếu DB trống
#  - Backup DB lên GitHub mỗi 30 phút
#  - Watchdog: tự restart bore + Java + MySQL nếu chết
# ================================================

set -uo pipefail

REPO="kgxxyixgikcgxittixxi-collab/rem5"
# Accept the historical secret spelling plus the normal spelling so a remix
# can bootstrap the private source/backup even if only one alias is present.
GH_TOKEN="${GITHUB_PERSOVNAL_ACCESS_TOKENBB:-${GITHUB_PERSONBAL_ACCESS_TOKENBB:-${GITHUB_PERSONAL_ACCESS_TOKEN:-}}}"
SRC_DIR="$HOME/rem5_src"
SERVER_DIR="$HOME/nro_server"
DB_DIR="$HOME/nro_mysql"
DB_SOCK="$HOME/nro_mysql/mysql.sock"
DB_NAME="team2026"
BORE_BIN="$HOME/workspace/server/bin/bore"
JAVA_BIN="/nix/store/3ilfkn8kxd9f6g5hgr0wpbnhghs4mq2m-openjdk-21.0.7+6/bin/java"
EXTRA_CP="$HOME/nro_extra/mysql-connector-java-5.1.49.jar"
LOG_GAME="$HOME/gameserver.log"
LOG_BORE="$HOME/bore.log"
LOG_DB="$HOME/mysql.log"
BACKUP_PATH="db_backup/latest.sql.gz"   # đường dẫn file trong repo GitHub
BACKUP_INTERVAL=1800                     # giây giữa 2 lần backup (30 phút)

OK="[OK]"; FAIL="[FAIL]"; WARN="[WARN]"; INFO=">>>"
log() { echo "$(date '+%H:%M:%S') $*"; }

# ════════════════════════════════════════════════
# 0. Clone rem5_src nếu chưa có (remix mới)
# ════════════════════════════════════════════════
if [ ! -d "$SRC_DIR/.git" ]; then
  log "$INFO [0] rem5_src chưa có — clone từ GitHub..."
  rm -rf "$SRC_DIR"
  if [ -n "$GH_TOKEN" ]; then
    CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
  else
    CLONE_URL="https://github.com/${REPO}.git"
  fi
  GIT_TERMINAL_PROMPT=0 git clone --depth=1 "$CLONE_URL" "$SRC_DIR" 2>&1 | tail -5
  log "$OK Clone xong"
else
  log "$INFO [0] rem5_src đã có, bỏ qua clone"
fi

# ════════════════════════════════════════════════
# 1. Khởi động MariaDB
# ════════════════════════════════════════════════
log "$INFO [1/5] Khởi động MariaDB..."
mkdir -p "$DB_DIR"

if [ ! -d "$DB_DIR/mysql" ]; then
  log "  → Khởi tạo DB lần đầu..."
  mysql_install_db \
    --datadir="$DB_DIR" \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    2>&1 | tail -5
  log "$OK mysql_install_db xong"
fi

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
MYSQL_PID=$!

log "  → Chờ MySQL khởi động (PID=$MYSQL_PID)..."
for i in $(seq 1 25); do
  sleep 1
  if [ -S "$DB_SOCK" ]; then
    log "$OK MySQL sẵn sàng (${i}s)"
    break
  fi
  if [ $i -eq 25 ]; then
    log "$FAIL MySQL không khởi động được! Log:"
    tail -20 "$LOG_DB" || true
    exit 1
  fi
done

mysql --socket="$DB_SOCK" -u root \
  -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true

# ════════════════════════════════════════════════
# 2. Restore DB (backup GitHub → SQL gốc → bỏ qua)
# ════════════════════════════════════════════════
TABLE_COUNT=$(mysql --socket="$DB_SOCK" -u root -N \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")

if [ "${TABLE_COUNT:-0}" -lt "5" ]; then
  RESTORED=0

  # Thử restore từ backup GitHub trước
  if [ -n "$GH_TOKEN" ]; then
    log "  → Kiểm tra backup trên GitHub ($BACKUP_PATH)..."
    BACKUP_URL="https://raw.githubusercontent.com/${REPO}/main/${BACKUP_PATH}"
    HTTP_CODE=$(curl -sf -o /tmp/db_restore.sql.gz \
      -H "Authorization: token $GH_TOKEN" \
      -w "%{http_code}" \
      "$BACKUP_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] && [ -s /tmp/db_restore.sql.gz ]; then
      log "  → Restore từ backup GitHub..."
      gunzip -c /tmp/db_restore.sql.gz | mysql --socket="$DB_SOCK" -u root "$DB_NAME" \
        && { log "$OK DB restored từ GitHub backup"; RESTORED=1; } \
        || log "$WARN Restore backup thất bại, thử SQL gốc..."
      rm -f /tmp/db_restore.sql.gz
    else
      log "  → Không có backup trên GitHub (HTTP $HTTP_CODE)"
    fi
  fi

  # Fallback: dùng file SQL gốc trong repo
  if [ $RESTORED -eq 0 ]; then
    SQL_FILE="$SRC_DIR/database team2026.sql"
    if [ -f "$SQL_FILE" ]; then
      log "  → Import database SQL gốc ($TABLE_COUNT tables)..."
      mysql --socket="$DB_SOCK" -u root "$DB_NAME" < "$SQL_FILE" \
        && log "$OK Database imported từ SQL gốc" \
        || log "$WARN Import SQL có lỗi, tiếp tục..."
    else
      log "$WARN Không tìm thấy file SQL: $SQL_FILE"
    fi
  fi
else
  log "$OK Database đã có ${TABLE_COUNT} bảng, bỏ qua restore"
fi

# ════════════════════════════════════════════════
# 3. mysql-connector + server files
# ════════════════════════════════════════════════
log "$INFO [3/5] Chuẩn bị files..."

if [ -f "$SRC_DIR/SRC/build.xml" ] && command -v ant >/dev/null 2>&1; then
  log "  → Build server JAR từ source..."
  (
    cd "$SRC_DIR/SRC"
    JAVA_HOME="$(dirname "$(dirname "$JAVA_BIN")")" \
      PATH="$(dirname "$JAVA_BIN"):$PATH" \
      ant -q clean jar
  ) && log "$OK Build JAR xong" \
    || { log "$FAIL Build JAR thất bại!"; exit 1; }
fi

if [ ! -f "$EXTRA_CP" ]; then
  log "  → Download mysql-connector 5.1.49..."
  mkdir -p "$HOME/nro_extra"
  curl -sLo "$EXTRA_CP" \
    https://repo1.maven.org/maven2/mysql/mysql-connector-java/5.1.49/mysql-connector-java-5.1.49.jar \
    && log "$OK mysql-connector-5.1.49 sẵn sàng" \
    || { log "$FAIL Download connector thất bại!"; exit 1; }
fi

mkdir -p "$SERVER_DIR"
if [ -d "$SRC_DIR/SRC/lib" ]; then
  rm -rf "$SERVER_DIR/lib"
  cp -r "$SRC_DIR/SRC/lib" "$SERVER_DIR/"
fi
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
cp "$SRC_DIR/SRC/Config.properties" "$SERVER_DIR/"

sed -i "s|database.host=.*|database.host=127.0.0.1|" "$SERVER_DIR/Config.properties"
sed -i "s|database.port=.*|database.port=3306|"       "$SERVER_DIR/Config.properties"
sed -i "s|database.pass=.*|database.pass=|"           "$SERVER_DIR/Config.properties"
sed -i "s|database.user=.*|database.user=root|"       "$SERVER_DIR/Config.properties"

find "$SERVER_DIR/data" -name "*[A-Z]*" 2>/dev/null | while read -r F; do
  DIR=$(dirname "$F"); BASE=$(basename "$F")
  LOWER=$(echo "$BASE" | tr '[:upper:]' '[:lower:]')
  [ "$BASE" != "$LOWER" ] && [ ! -e "$DIR/$LOWER" ] && ln -sf "$F" "$DIR/$LOWER"
done
log "$OK Server files sẵn sàng"

# ════════════════════════════════════════════════
# 4. Bore tunnel
# ════════════════════════════════════════════════
log "$INFO [4/5] Khởi động bore tunnel..."

if [ ! -f "$BORE_BIN" ]; then
  log "  → Download bore binary..."
  mkdir -p "$(dirname "$BORE_BIN")"
  curl -sLo /tmp/bore.tgz \
    https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz
  tar -xzf /tmp/bore.tgz -C "$(dirname "$BORE_BIN")/"
  chmod +x "$BORE_BIN"
fi

TUNNEL_HOST="bore.pub"
start_tunnel() {
  pkill -f "bore local 14445" 2>/dev/null || true
  TUNNEL_PORT=""
  for TRY_PORT in $(seq 20445 20460); do
    > "$LOG_BORE"
    "$BORE_BIN" local 14445 --to bore.pub --port "$TRY_PORT" >> "$LOG_BORE" 2>&1 &
    TUNNEL_PID=$!
    for _ in $(seq 1 5); do
      sleep 1
      TUNNEL_PORT=$(grep -oE 'listening at bore\.pub:[0-9]+' "$LOG_BORE" \
        | grep -oE '[0-9]+$' | tail -1 || true)
      [ -n "$TUNNEL_PORT" ] && return 0
      kill -0 "$TUNNEL_PID" 2>/dev/null || break
    done
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  done
  log "$FAIL Không tìm được cổng bore trống (20445-20460)"
  return 1
}

start_tunnel || exit 1
log "$OK bore.pub:$TUNNEL_PORT"

sed -i "s|server.ip=.*|server.ip=$TUNNEL_HOST|"                       "$SERVER_DIR/Config.properties"
sed -i "s|server.external_port=.*|server.external_port=$TUNNEL_PORT|" "$SERVER_DIR/Config.properties"
sed -i "s|server.sv1=.*|server.sv1=|"                                 "$SERVER_DIR/Config.properties"

# ════════════════════════════════════════════════
# 5. Java server
# ════════════════════════════════════════════════
log "$INFO [5/5] Khởi động Java server..."

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

# ════════════════════════════════════════════════
# Hàm tiện ích: ghi port + backup DB
# ════════════════════════════════════════════════
write_server_ip() {
  local port=$1
  printf 'HOST=bore.pub\nPORT=%s\nSTATUS=RUNNING\nUPDATED=%s UTC\n' \
    "$port" "$(date '+%Y-%m-%d %H:%M:%S')" \
    > "$HOME/workspace/server/SERVER_PORT.txt"

  [ -z "$GH_TOKEN" ] && return 0
  local CONTENT_B64
  CONTENT_B64=$(printf 'HOST=bore.pub\nPORT=%s\nSTATUS=RUNNING\nUPDATED=%s UTC\n' \
    "$port" "$(date '+%Y-%m-%d %H:%M:%S')" | base64 -w 0)
  local SHA
  SHA=$(curl -sf -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).sha||'')}catch(e){console.log('')}})" 2>/dev/null || echo "")
  local PAYLOAD
  [ -n "$SHA" ] \
    && PAYLOAD="{\"message\":\"[Replit] bore.pub:$port [skip ci]\",\"content\":\"$CONTENT_B64\",\"sha\":\"$SHA\"}" \
    || PAYLOAD="{\"message\":\"[Replit] bore.pub:$port [skip ci]\",\"content\":\"$CONTENT_B64\"}"
  curl -sf -X PUT \
    -H "Authorization: token $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    -d "$PAYLOAD" >/dev/null \
    && log "$OK SERVER_IP.txt → bore.pub:$port" \
    || log "$WARN Ghi SERVER_IP.txt thất bại"
}

backup_db_to_github() {
  [ -z "$GH_TOKEN" ] && { log "$WARN Bỏ qua backup: không có token"; return 0; }
  log "  [backup] Bắt đầu dump DB..."
  mysqldump --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null \
    | gzip -9 > /tmp/db_backup_upload.sql.gz
  local SIZE
  SIZE=$(wc -c < /tmp/db_backup_upload.sql.gz)
  log "  [backup] Dump xong: ${SIZE} bytes nén"

  # Lấy SHA file cũ (nếu tồn tại)
  local SHA
  SHA=$(curl -sf -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/contents/$BACKUP_PATH" \
    | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).sha||'')}catch(e){console.log('')}})" 2>/dev/null || echo "")

  local TS
  TS=$(date '+%Y-%m-%d %H:%M UTC')

  # Dùng node để build JSON payload + gọi GitHub API
  # (tránh lỗi "Argument list too long" khi dùng -d "..." trong shell)
  node - <<NODEJS
const fs = require('fs');
const { execSync } = require('child_process');
const content = fs.readFileSync('/tmp/db_backup_upload.sql.gz').toString('base64');
const sha = '${SHA}';
const payload = JSON.stringify({
  message: '[backup] DB ${TS} [skip ci]',
  content,
  ...(sha ? { sha } : {})
});
fs.writeFileSync('/tmp/gh_payload.json', payload);

const res = execSync(
  'curl -sf -X PUT' +
  ' -H "Authorization: token ${GH_TOKEN}"' +
  ' -H "Accept: application/vnd.github+json"' +
  ' -H "Content-Type: application/json"' +
  ' "https://api.github.com/repos/${REPO}/contents/${BACKUP_PATH}"' +
  ' -d @/tmp/gh_payload.json',
  { encoding: 'utf8', timeout: 60000 }
);
const json = JSON.parse(res);
if (json.content) {
  console.log('OK sha=' + json.content.sha.slice(0,8));
} else {
  console.error('FAIL ' + res.slice(0,200));
  process.exit(1);
}
NODEJS
  local EXIT=$?
  if [ $EXIT -eq 0 ]; then
    log "$OK [backup] DB → GitHub ($BACKUP_PATH) thành công"
  else
    log "$WARN [backup] Push GitHub thất bại (exit $EXIT)"
  fi
  rm -f /tmp/db_backup_upload.sql.gz /tmp/gh_payload.json
}

# Ghi port ban đầu
write_server_ip "$TUNNEL_PORT"
# Backup lần đầu ngay sau khi khởi động (đảm bảo có backup mới nhất)
backup_db_to_github

log ""
log "======================================================"
log "  NRO SERVER CHAY TREN REPLIT"
log "  HOST : $TUNNEL_HOST  PORT : $TUNNEL_PORT"
log "  Backup DB  : moi ${BACKUP_INTERVAL}s (~$(( BACKUP_INTERVAL/60 )) phut)"
log "  Log game   : tail -f $LOG_GAME"
log "======================================================"
log ""

# ════════════════════════════════════════════════
# Watchdog loop
# ════════════════════════════════════════════════
log "$INFO Monitor loop (check moi 30s)..."
BORE_FAIL=0; JAVA_FAIL=0
LAST_BACKUP=$(date +%s)

while true; do
  sleep 30

  # --- Bore ---
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    BORE_FAIL=$((BORE_FAIL+1))
    log "$WARN Tunnel chet lan $BORE_FAIL! Restart..."
    start_tunnel
    sed -i "s|server.external_port=.*|server.external_port=$TUNNEL_PORT|" "$SERVER_DIR/Config.properties"
    write_server_ip "$TUNNEL_PORT"
    log "$OK Tunnel moi: bore.pub:$TUNNEL_PORT"
  fi

  # --- Java ---
  if ! kill -0 "$JAVA_PID" 2>/dev/null; then
    JAVA_FAIL=$((JAVA_FAIL+1))
    log "$WARN Java chet lan $JAVA_FAIL! Restart..."
    JAVA_PID=$(start_java)
    sleep 8
    kill -0 "$JAVA_PID" 2>/dev/null \
      && log "$OK Java restart OK (PID=$JAVA_PID)" \
      || { log "$FAIL Java van khong len!"; tail -20 "$LOG_GAME" || true; }
  fi

  # --- MySQL ---
  if ! kill -0 "$MYSQL_PID" 2>/dev/null; then
    log "$WARN MySQL chet! Restart..."
    mysqld --no-defaults --datadir="$DB_DIR" --socket="$DB_SOCK" \
      --pid-file="$DB_DIR/mysql.pid" --port=3306 --bind-address=127.0.0.1 \
      --skip-networking=OFF --log-error="$LOG_DB" --skip-grant-tables \
      2>>"$LOG_DB" &
    MYSQL_PID=$!; sleep 5
    log "$OK MySQL restarted"
  fi

  # --- Backup DB định kỳ ---
  NOW=$(date +%s)
  if [ $(( NOW - LAST_BACKUP )) -ge $BACKUP_INTERVAL ]; then
    backup_db_to_github
    LAST_BACKUP=$NOW
  fi
done
