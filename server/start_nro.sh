#!/bin/bash
# ================================================
#  NRO Game Server - Replit Runner  (hardened v4)
#  Kịch bản được xử lý:
#  [DATA SAFETY]
#  - Remix / container reset mới hoàn toàn
#  - Mất kết nối GitHub (fallback local backup)
#  - SIGTERM trap → backup trước khi thoát (đúng thứ tự)
#  - Fast local backup mỗi 2 phút (không cần mạng, không block)
#  - Full backup (local + GitHub) mỗi 5 phút
#  - GitHub upload retry 3 lần khi thất bại
#  - Verify table count sau mỗi restore
#  - Clone integrity check (verify JAR tồn tại sau clone)
#  [STABILITY]
#  - bore port bị chiếm → tự tìm port khác
#  - Java crash → watchdog backup + restart
#  - MySQL crash → watchdog restart MySQL + restart Java (conn pool cũ)
#  - bore crash → watchdog restart tunnel + cập nhật Config
#  - Java path thay đổi sau Nix update → tự tìm
#  - mysql-connector download lỗi → retry 3 lần
#  - Clone repo thất bại → retry 3 lần với delay
#  - MySQL health check thực (query, không chỉ kill -0)
#  [RESTORE ORDER]
#  Local workspace (persistent) → GitHub → SQL gốc trong repo
# ================================================

set -uo pipefail

# ────────────────────────────────────────────────
# Biến cấu hình
# ────────────────────────────────────────────────
REPO="kgxxyixgikcgxittixxi-collab/rem5"

# Thử tất cả các biến token có thể có (theo thứ tự ưu tiên)
GH_TOKEN=""
for _VAR in \
    GITHUB_PERSDONAL_ACCESS_TOKENHHD \
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

SRC_DIR="$HOME/rem5_src"
SERVER_DIR="$HOME/nro_server"
DB_DIR="$HOME/nro_mysql"
DB_SOCK="$HOME/nro_mysql/mysql.sock"
DB_NAME="team2026"
BORE_BIN="$HOME/workspace/server/bin/bore"
EXTRA_CP="$HOME/nro_extra/mysql-connector-java-5.1.49.jar"
LOG_GAME="$HOME/gameserver.log"
LOG_BORE="$HOME/bore.log"
LOG_DB="$HOME/mysql.log"

# Backup paths
GITHUB_BACKUP_PATH="db_backup/latest.sql.gz"
LOCAL_BACKUP="$HOME/workspace/server/db_backup/latest.sql.gz"
LOCAL_BACKUP_FAST="$HOME/workspace/server/db_backup/fast.sql.gz"

# Intervals
BACKUP_FULL_INTERVAL=300     # full backup (local + GitHub) mỗi 5 phút
BACKUP_FAST_INTERVAL=120     # fast local-only backup mỗi 2 phút
MIN_BACKUP_BYTES=5000        # backup phải > 5KB mới hợp lệ

OK="[OK]"; FAIL="[FAIL]"; WARN="[WARN]"; INFO=">>>"
log() { echo "$(date '+%H:%M:%S') $*"; }

mkdir -p "$HOME/workspace/server/db_backup"

# ────────────────────────────────────────────────
# Tự động tìm Java binary (không hardcode nix path)
# ────────────────────────────────────────────────
find_java() {
  local CANDIDATES=(
    "/nix/store/3ilfkn8kxd9f6g5hgr0wpbnhghs4mq2m-openjdk-21.0.7+6/bin/java"
  )
  for J in "${CANDIDATES[@]}"; do
    [ -x "$J" ] && { echo "$J"; return 0; }
  done
  local J
  J=$(find /nix/store -maxdepth 3 -name "java" -path "*/openjdk-21*" 2>/dev/null | head -1)
  [ -n "$J" ] && { echo "$J"; return 0; }
  which java 2>/dev/null && return 0
  return 1
}

JAVA_BIN=$(find_java) || { log "$FAIL Không tìm thấy Java 21!"; exit 1; }
log "$INFO Java: $JAVA_BIN"

# ════════════════════════════════════════════════
# 0. Clone rem5_src nếu chưa có hoặc bị corrupt
# ════════════════════════════════════════════════

# Kiểm tra integrity: không chỉ .git mà phải có JAR hoặc build.xml
src_is_valid() {
  [ -d "$SRC_DIR/.git" ] || return 1
  [ -f "$SRC_DIR/SRC/dist/NgocRongOnline.jar" ] \
    || [ -f "$SRC_DIR/SRC/20.jar" ] \
    || [ -f "$SRC_DIR/SRC/build.xml" ] || return 1
  return 0
}

if ! src_is_valid; then
  log "$INFO [0] rem5_src chưa có hoặc không đầy đủ — clone từ GitHub..."
  rm -rf "$SRC_DIR"
  if [ -n "$GH_TOKEN" ]; then
    CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
  else
    CLONE_URL="https://github.com/${REPO}.git"
  fi
  # Retry clone tối đa 3 lần
  CLONE_OK=0
  for _TRY in 1 2 3; do
    log "  → Clone lần $_TRY..."
    if GIT_TERMINAL_PROMPT=0 git clone --depth=1 "$CLONE_URL" "$SRC_DIR" 2>&1 | tail -3; then
      if src_is_valid; then
        log "$OK Clone xong (lần $_TRY)"
        CLONE_OK=1
        break
      else
        log "$WARN Clone xong nhưng thiếu file JAR/build.xml!"
      fi
    fi
    rm -rf "$SRC_DIR"
    [ $_TRY -lt 3 ] && { log "  → Thử lại sau 15s..."; sleep 15; }
  done
  [ $CLONE_OK -eq 0 ] && { log "$FAIL Clone thất bại sau 3 lần!"; exit 1; }
else
  log "$INFO [0] rem5_src đã có và hợp lệ, bỏ qua clone"
fi

# Chẩn đoán protocol tạm thời: ghi command/kích thước gói sau key exchange,
# không ghi nội dung payload để tránh lộ tài khoản hoặc mật khẩu.
apply_protocol_diagnostics() {
  local COLLECTOR="$SRC_DIR/SRC/src/nro/models/network/Collector.java"
  [ -f "$COLLECTOR" ] || return 0
  python3 - "$COLLECTOR" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = 'import nro.models.interfaces.ISession;'
addition = 'import nro.models.utils.Logger;'
needle = '''                Message msg = this.collect.readMessage(this.session, this.dis);
                if (msg.command == -27) {'''
replacement = '''                Message msg = this.collect.readMessage(this.session, this.dis);
                Logger.warning("[PROTO] ip=" + this.session.getIP()
                        + " cmd=" + msg.command
                        + " bytes=" + (msg.getData() == null ? 0 : msg.getData().length)
                        + " key=" + this.session.sentKey() + "\\n");
                if (msg.command == -27) {'''
if "[PROTO] ip=" not in text:
    if addition not in text:
        text = text.replace(marker, marker + "\n" + addition, 1)
    if needle not in text:
        raise SystemExit("Collector.java protocol hook location not found")
    text = text.replace(needle, replacement, 1)
    path.write_text(text, encoding="utf-8")
PY
}

apply_protocol_diagnostics

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

# Hàm start mysqld (dùng lại trong watchdog)
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

# Kiểm tra MySQL thực sự đang nhận query (không chỉ process alive)
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
    log "$FAIL MySQL không khởi động được! Log:"
    tail -20 "$LOG_DB" || true
    exit 1
  fi
done

mysql --socket="$DB_SOCK" -u root \
  -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true

# ════════════════════════════════════════════════
# 2. Restore DB theo thứ tự ưu tiên:
#    1. Local workspace backup (persistent, không cần mạng)
#    2. GitHub backup
#    3. SQL gốc trong repo
# ════════════════════════════════════════════════
TABLE_COUNT=$(mysql --socket="$DB_SOCK" -u root -N \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")

# Hàm verify sau restore
verify_restore() {
  local TC
  TC=$(mysql --socket="$DB_SOCK" -u root -N \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")
  [ "${TC:-0}" -ge 5 ]
}

if [ "${TABLE_COUNT:-0}" -lt "5" ]; then
  RESTORED=0

  # --- Ưu tiên 1: Local workspace backup (persistent) ---
  for _BACKUP_FILE in "$LOCAL_BACKUP" "$LOCAL_BACKUP_FAST"; do
    if [ $RESTORED -eq 0 ] && [ -f "$_BACKUP_FILE" ] \
       && [ "$(wc -c < "$_BACKUP_FILE" 2>/dev/null || echo 0)" -gt "$MIN_BACKUP_BYTES" ]; then
      log "  → Restore từ LOCAL backup: $_BACKUP_FILE..."
      if gunzip -c "$_BACKUP_FILE" | mysql --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null; then
        if verify_restore; then
          log "$OK DB restored từ local backup"
          # Đồng bộ latest = fast nếu cần
          [ "$_BACKUP_FILE" = "$LOCAL_BACKUP_FAST" ] && cp "$_BACKUP_FILE" "$LOCAL_BACKUP" || true
          RESTORED=1
        else
          log "$WARN Restore local backup xong nhưng < 5 bảng, thử tiếp..."
          mysql --socket="$DB_SOCK" -u root -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
        fi
      else
        log "$WARN Restore $_BACKUP_FILE thất bại"
      fi
    fi
  done

  # --- Ưu tiên 2: GitHub backup ---
  if [ $RESTORED -eq 0 ] && [ -n "$GH_TOKEN" ]; then
    log "  → Kiểm tra backup trên GitHub ($GITHUB_BACKUP_PATH)..."
    BACKUP_URL="https://raw.githubusercontent.com/${REPO}/main/${GITHUB_BACKUP_PATH}"
    HTTP_CODE=$(curl -sf -o /tmp/db_restore.sql.gz \
      -H "Authorization: token $GH_TOKEN" \
      -w "%{http_code}" \
      "$BACKUP_URL" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] && [ -f /tmp/db_restore.sql.gz ] \
       && [ "$(wc -c < /tmp/db_restore.sql.gz 2>/dev/null || echo 0)" -gt "$MIN_BACKUP_BYTES" ]; then
      log "  → Restore từ GitHub backup..."
      if gunzip -c /tmp/db_restore.sql.gz | mysql --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null; then
        if verify_restore; then
          log "$OK DB restored từ GitHub backup"
          cp /tmp/db_restore.sql.gz "$LOCAL_BACKUP"
          cp /tmp/db_restore.sql.gz "$LOCAL_BACKUP_FAST"
          RESTORED=1
        else
          log "$WARN GitHub restore xong nhưng < 5 bảng!"
        fi
      else
        log "$WARN Restore GitHub backup thất bại"
      fi
      rm -f /tmp/db_restore.sql.gz
    else
      log "  → Không có GitHub backup hợp lệ (HTTP $HTTP_CODE)"
    fi
  fi

  # --- Ưu tiên 3: SQL gốc trong repo (fallback cuối) ---
  if [ $RESTORED -eq 0 ]; then
    SQL_FILE="$SRC_DIR/database team2026.sql"
    if [ -f "$SQL_FILE" ]; then
      log "  → Import database SQL gốc (fallback)..."
      mysql --socket="$DB_SOCK" -u root "$DB_NAME" < "$SQL_FILE" \
        && log "$OK Database imported từ SQL gốc" \
        || log "$WARN Import SQL có lỗi nhỏ, tiếp tục..."
    else
      log "$WARN Không tìm thấy file SQL gốc: $SQL_FILE"
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
  DOWNLOAD_OK=0
  for _TRY in 1 2 3; do
    if curl -sLo "$EXTRA_CP" \
        https://repo1.maven.org/maven2/mysql/mysql-connector-java/5.1.49/mysql-connector-java-5.1.49.jar \
        && [ -f "$EXTRA_CP" ] && [ "$(wc -c < "$EXTRA_CP")" -gt 100000 ]; then
      log "$OK mysql-connector-5.1.49 sẵn sàng (lần $_TRY)"
      DOWNLOAD_OK=1
      break
    fi
    log "$WARN Download lần $_TRY thất bại, thử lại..."
    rm -f "$EXTRA_CP"
    sleep 5
  done
  [ $DOWNLOAD_OK -eq 0 ] && { log "$FAIL Download connector thất bại sau 3 lần!"; exit 1; }
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

if [ ! -f "$BORE_BIN" ] || [ "$(wc -c < "$BORE_BIN")" -lt 100000 ]; then
  log "  → Download bore binary..."
  mkdir -p "$(dirname "$BORE_BIN")"
  curl -sLo /tmp/bore.tgz \
    https://github.com/ekzhang/bore/releases/download/v0.5.1/bore-v0.5.1-x86_64-unknown-linux-musl.tar.gz \
    && tar -xzf /tmp/bore.tgz -C "$(dirname "$BORE_BIN")/" \
    && chmod +x "$BORE_BIN" \
    || { log "$FAIL Download bore thất bại!"; exit 1; }
fi

TUNNEL_HOST="bore.pub"
TUNNEL_PORT=""
TUNNEL_PID=""

start_tunnel() {
  # Kill tunnel cũ (by PID trước, rồi pkill toàn bộ)
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  pkill -f "bore local 14445" 2>/dev/null || true
  pkill -f "bore local" 2>/dev/null || true
  sleep 3   # chờ OS giải phóng port phía bore.pub
  TUNNEL_PORT=""

  # Thử port 20445 trước (client cũ hardcode); nếu bị chiếm thử 20446-20460
  for TRY_PORT in 20445 20446 20447 20448 20449 20450 20460; do
    > "$LOG_BORE"
    "$BORE_BIN" local 14445 --to bore.pub --port "$TRY_PORT" >> "$LOG_BORE" 2>&1 &
    TUNNEL_PID=$!
    for i in $(seq 1 12); do
      sleep 1
      if grep -qE 'listening at bore\.pub' "$LOG_BORE" 2>/dev/null; then
        TUNNEL_PORT=$TRY_PORT
        return 0
      fi
      kill -0 "$TUNNEL_PID" 2>/dev/null || break
    done
    kill "$TUNNEL_PID" 2>/dev/null; wait "$TUNNEL_PID" 2>/dev/null || true
    log "  → Port $TRY_PORT bị chiếm, thử tiếp..."
    sleep 2
  done

  log "$FAIL Không tìm được bore port trong dải 20445-20460."
  return 1
}

start_tunnel || exit 1
log "$OK bore.pub:$TUNNEL_PORT"

sed -i "s|server.ip=.*|server.ip=$TUNNEL_HOST|"                       "$SERVER_DIR/Config.properties"
sed -i "s|server.external_port=.*|server.external_port=$TUNNEL_PORT|" "$SERVER_DIR/Config.properties"
sed -i "s|server.sv1=.*|server.sv1=|"                                 "$SERVER_DIR/Config.properties"

# ════════════════════════════════════════════════
# Hàm backup nhanh (local only, không block lâu)
# ════════════════════════════════════════════════
backup_local_fast() {
  # Dump không blocking: chạy ngầm, không upload GitHub
  (
    local TMP="/tmp/db_fast_$$.sql.gz"
    mysqldump --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null | gzip -1 > "$TMP"
    local SIZE
    SIZE=$(wc -c < "$TMP" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt "$MIN_BACKUP_BYTES" ]; then
      mv "$TMP" "$LOCAL_BACKUP_FAST"
      # Cũng cập nhật latest nếu fast mới hơn
      cp "$LOCAL_BACKUP_FAST" "$LOCAL_BACKUP" 2>/dev/null || true
      log "$OK [fast-backup] ${SIZE} bytes → local"
    else
      rm -f "$TMP"
      log "$WARN [fast-backup] dump quá nhỏ (${SIZE}b), bỏ qua"
    fi
  ) &
}

# ════════════════════════════════════════════════
# Hàm backup đầy đủ (local + GitHub với retry)
# ════════════════════════════════════════════════
backup_db() {
  local REASON="${1:-scheduled}"
  log "  [backup:$REASON] Bắt đầu dump DB..."

  local TMP="/tmp/db_backup_$$.sql.gz"
  # Dùng file tạm có PID để tránh conflict nếu 2 backup chạy song song
  mysqldump --socket="$DB_SOCK" -u root "$DB_NAME" 2>/dev/null \
    | gzip -9 > "$TMP"
  local DUMP_EXIT=${PIPESTATUS[0]}

  local SIZE
  SIZE=$(wc -c < "$TMP" 2>/dev/null || echo 0)

  if [ "$DUMP_EXIT" -ne 0 ] || [ "$SIZE" -lt "$MIN_BACKUP_BYTES" ]; then
    log "$WARN [backup:$REASON] mysqldump thất bại hoặc quá nhỏ (exit=$DUMP_EXIT size=${SIZE}b)"
    rm -f "$TMP"
    return 1
  fi

  log "  [backup:$REASON] Dump xong: ${SIZE} bytes"

  # --- Local backup (luôn làm trước, không cần mạng) ---
  cp "$TMP" "$LOCAL_BACKUP" \
    && cp "$TMP" "$LOCAL_BACKUP_FAST" \
    && log "$OK [backup:$REASON] Local backup saved" \
    || log "$WARN [backup:$REASON] Local backup thất bại"

  # --- GitHub backup với retry 3 lần ---
  if [ -z "$GH_TOKEN" ]; then
    log "$WARN [backup:$REASON] Không có GitHub token, chỉ giữ local"
    rm -f "$TMP"
    return 0
  fi

  local GH_OK=0
  for _TRY in 1 2 3; do
    local SHA
    SHA=$(curl -sf -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/contents/$GITHUB_BACKUP_PATH" \
      | node -e "let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{try{console.log(JSON.parse(d).sha||'')}catch(e){console.log('')}})" 2>/dev/null || echo "")

    local TS
    TS=$(date '+%Y-%m-%d %H:%M UTC')

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
  } else {
    console.error('FAIL ' + res.slice(0,200));
    process.exit(1);
  }
} catch(e) {
  console.error('FAIL ' + e.message);
  process.exit(1);
}
NODEJS
    if [ $? -eq 0 ]; then
      log "$OK [backup:$REASON] GitHub backup thành công (lần $_TRY)"
      GH_OK=1
      break
    fi
    log "$WARN [backup:$REASON] GitHub backup lần $_TRY thất bại"
    [ $_TRY -lt 3 ] && sleep 10
  done

  [ $GH_OK -eq 0 ] && log "$WARN [backup:$REASON] GitHub backup thất bại cả 3 lần (đã có local backup)"
  rm -f "$TMP" "/tmp/gh_payload_$$.json"
}

# ════════════════════════════════════════════════
# Hàm ghi SERVER_IP.txt + GitHub
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
# SIGTERM trap: backup ĐÚNG THỨ TỰ trước khi thoát
# ════════════════════════════════════════════════
cleanup() {
  log "$WARN Nhận tín hiệu tắt — backup khẩn cấp..."
  # Bước 1: Backup DB (MySQL vẫn còn sống)
  backup_db "shutdown"
  # Bước 2: Dừng Java trước (ngăn write mới)
  log "$INFO Dừng Java..."
  kill "$JAVA_PID" 2>/dev/null || true
  wait "$JAVA_PID" 2>/dev/null || true
  # Bước 3: Dừng tunnel
  log "$INFO Dừng bore tunnel..."
  kill "$TUNNEL_PID" 2>/dev/null || true
  # Bước 4: Dừng MySQL sau cùng
  log "$INFO Dừng MySQL..."
  kill "$MYSQL_PID" 2>/dev/null || true
  wait "$MYSQL_PID" 2>/dev/null || true
  log "$OK Đã dừng sạch."
  exit 0
}
trap cleanup SIGTERM SIGINT

# ════════════════════════════════════════════════
# Startup: ghi port + backup lần đầu
# ════════════════════════════════════════════════
write_server_ip "$TUNNEL_PORT"
backup_db "startup"

log ""
log "======================================================"
log "  NRO SERVER CHAY TREN REPLIT  (hardened v4)"
log "  HOST : $TUNNEL_HOST  PORT : $TUNNEL_PORT"
log "  Fast local backup : moi ${BACKUP_FAST_INTERVAL}s"
log "  Full backup (GH)  : moi ${BACKUP_FULL_INTERVAL}s"
log "  Local  : $LOCAL_BACKUP"
log "  Log    : tail -f $LOG_GAME"
log "======================================================"
log ""

# ════════════════════════════════════════════════
# Watchdog loop
# ════════════════════════════════════════════════
log "$INFO Watchdog loop (check moi 30s)..."
BORE_FAIL=0; JAVA_FAIL=0; MYSQL_FAIL=0
LAST_FULL_BACKUP=$(date +%s)
LAST_FAST_BACKUP=$(date +%s)

while true; do
  sleep 30

  NOW=$(date +%s)

  # ── Fast local backup (mỗi 2 phút, không block) ──
  if [ $(( NOW - LAST_FAST_BACKUP )) -ge $BACKUP_FAST_INTERVAL ]; then
    backup_local_fast
    LAST_FAST_BACKUP=$NOW
  fi

  # ── MySQL health check (query thực, không chỉ kill -0) ──
  MYSQL_ALIVE=0
  if kill -0 "$MYSQL_PID" 2>/dev/null && mysql_is_alive; then
    MYSQL_ALIVE=1
  fi

  if [ $MYSQL_ALIVE -eq 0 ]; then
    MYSQL_FAIL=$((MYSQL_FAIL+1))
    log "$WARN MySQL chết lần $MYSQL_FAIL! Restart MySQL..."
    MYSQL_PID=$(start_mysql)
    # Chờ MySQL lên
    for _W in $(seq 1 20); do
      sleep 1
      mysql_is_alive && break
    done
    if mysql_is_alive; then
      log "$OK MySQL restarted (PID=$MYSQL_PID)"
      # QUAN TRỌNG: Restart Java sau MySQL vì connection pool cũ không dùng được
      log "$WARN Restart Java do MySQL vừa restart (connection pool cũ invalid)..."
      backup_db "mysql-restart"
      JAVA_PID=$(start_java)
      sleep 8
      kill -0 "$JAVA_PID" 2>/dev/null \
        && log "$OK Java restarted sau MySQL restart (PID=$JAVA_PID)" \
        || { log "$FAIL Java không lên sau MySQL restart!"; tail -20 "$LOG_GAME" || true; }
    else
      log "$FAIL MySQL vẫn không lên sau restart!"
      tail -20 "$LOG_DB" || true
    fi
  fi

  # ── Bore tunnel health check ──
  # Dùng /dev/tcp: chỉ test TCP handshake (kết nối thành công = port open = tunnel alive)
  # Khác với nc: /dev/tcp trả 0 khi connect xong, dù server đóng ngay sau đó
  BORE_ALIVE=0
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    if timeout 5 bash -c "exec 3<>/dev/tcp/bore.pub/$TUNNEL_PORT && exec 3>&-" 2>/dev/null; then
      BORE_ALIVE=1
    fi
  fi

  if [ $BORE_ALIVE -eq 0 ]; then
    BORE_FAIL=$((BORE_FAIL+1))
    if kill -0 "$TUNNEL_PID" 2>/dev/null; then
      log "$WARN Bore zombie (PID=$TUNNEL_PID sống nhưng bore.pub:$TUNNEL_PORT UNREACHABLE)! Kill..."
      kill "$TUNNEL_PID" 2>/dev/null || true
      sleep 1
    fi
    log "$WARN Tunnel lần $BORE_FAIL! Restart..."
    start_tunnel && {
      sed -i "s|server.external_port=.*|server.external_port=$TUNNEL_PORT|" "$SERVER_DIR/Config.properties"
      write_server_ip "$TUNNEL_PORT"
      log "$OK Tunnel mới: bore.pub:$TUNNEL_PORT"
    } || log "$FAIL Tunnel restart thất bại lần $BORE_FAIL"
  fi

  # ── Java health check (port thực, không chỉ kill -0) ──
  # Java "zombie": process sống nhưng port đóng → cần kill và restart
  JAVA_PORT_HEX=$(printf "%04X" 14445)
  JAVA_PORT_OK=0
  grep -qi "$JAVA_PORT_HEX" /proc/net/tcp /proc/net/tcp6 2>/dev/null && JAVA_PORT_OK=1

  if ! kill -0 "$JAVA_PID" 2>/dev/null || [ $JAVA_PORT_OK -eq 0 ]; then
    JAVA_FAIL=$((JAVA_FAIL+1))
    if kill -0 "$JAVA_PID" 2>/dev/null && [ $JAVA_PORT_OK -eq 0 ]; then
      log "$WARN Java zombie (PID=$JAVA_PID sống nhưng port 14445 ĐÓNG)! Kill..."
      kill -9 "$JAVA_PID" 2>/dev/null || true
      sleep 2
    fi
    log "$WARN Java lần $JAVA_FAIL! Backup + restart..."
    backup_db "java-crash"
    JAVA_PID=$(start_java)
    # Chờ port thực sự mở (tối đa 30s)
    for _W in $(seq 1 15); do
      sleep 2
      grep -qi "$JAVA_PORT_HEX" /proc/net/tcp /proc/net/tcp6 2>/dev/null && break
    done
    grep -qi "$JAVA_PORT_HEX" /proc/net/tcp /proc/net/tcp6 2>/dev/null \
      && log "$OK Java restart OK — port 14445 listen (PID=$JAVA_PID)" \
      || { log "$FAIL Java lên nhưng port 14445 vẫn đóng!"; tail -20 "$LOG_GAME" || true; }
  fi

  # ── Full backup định kỳ (local + GitHub) ──
  if [ $(( NOW - LAST_FULL_BACKUP )) -ge $BACKUP_FULL_INTERVAL ]; then
    backup_db "scheduled"
    LAST_FULL_BACKUP=$NOW
  fi

done
