#!/bin/bash

echo "======================================"
echo "   KHỞI ĐỘNG NGOC RONG SERVER         "
echo "======================================"

REPO="kgxxyixgikcgxittixxi-collab/rem5"
SERVER_DIR=~/nro_server
WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Fix MariaDB TCP + Khởi động MySQL
echo ">>> [1/5] Cấu hình và khởi động MySQL..."
MYSQL_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
if [ -f "$MYSQL_CONF" ]; then
    sudo sed -i 's/^skip-networking/#skip-networking/' "$MYSQL_CONF"
    if grep -q "^bind-address" "$MYSQL_CONF"; then
        sudo sed -i 's/^bind-address.*/bind-address = 127.0.0.1/' "$MYSQL_CONF"
    else
        echo "bind-address = 127.0.0.1" | sudo tee -a "$MYSQL_CONF" > /dev/null
    fi
fi
if [ ! -f "$MYSQL_CONF" ]; then
    echo -e "[mysqld]\nbind-address = 127.0.0.1\nskip-networking = 0" \
        | sudo tee /etc/mysql/conf.d/tcp-fix.cnf > /dev/null
fi
sudo service mariadb start 2>/dev/null || sudo service mysql start 2>/dev/null || true
sleep 2

DB_EXISTS=$(sudo mysql -e "SHOW DATABASES LIKE 'team2026';" 2>/dev/null | grep team2026 || true)
if [ -z "$DB_EXISTS" ]; then
    echo ">>> Import database lần đầu..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS team2026 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null || true
    sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null || true
    if [ -f "$WORKSPACE_DIR/database team2026.sql" ]; then
        sudo mysql team2026 < "$WORKSPACE_DIR/database team2026.sql" && echo "✅ DB imported"
    fi
fi

# 2. Build JAR từ source (fix LINK_IP_PORT + fix stdin crash)
echo ">>> [2/5] Build JAR từ source..."
# Cài ant nếu chưa có
if ! command -v ant &>/dev/null; then
    echo "  → Cài ant..."
    sudo apt-get install -y -qq ant 2>/dev/null && echo "✅ ant OK" || echo "⚠️  ant install failed"
fi

BUILD_SUCCESS=false
if command -v ant &>/dev/null; then
    cd "$WORKSPACE_DIR/SRC"
    ant -q clean jar 2>/tmp/build.log && BUILD_SUCCESS=true || true
    if [ "$BUILD_SUCCESS" = "true" ]; then
        echo "✅ Build JAR thành công"
        cp "$WORKSPACE_DIR/SRC/dist/NgocRongOnline.jar" ~/nro_server/NgocRongOnline.jar 2>/dev/null || true
    else
        echo "⚠️  ant build lỗi, dùng JAR cũ"
        tail -20 /tmp/build.log
    fi
else
    echo "⚠️  ant không có, dùng JAR cũ"
fi

# Chuẩn bị server files lần đầu nếu chưa có
if [ ! -f "$SERVER_DIR/NgocRongOnline.jar" ]; then
    echo ">>> Copy server files lần đầu..."
    mkdir -p ~/nro_server
    cp -r "$WORKSPACE_DIR/SRC/dist/." ~/nro_server/
    cp -r "$WORKSPACE_DIR/SRC/data" ~/nro_server/ 2>/dev/null || true
    cp "$WORKSPACE_DIR/SRC/Config.properties" ~/nro_server/
fi
# Sync data và config
cp -r "$WORKSPACE_DIR/SRC/data" ~/nro_server/ 2>/dev/null || true
cp "$WORKSPACE_DIR/SRC/Config.properties" ~/nro_server/Config.properties.bak 2>/dev/null || true

# 3. Khởi động tunnel bore (thử port cố định 14445-14460)
echo ">>> [3/5] Khởi động bore tunnel..."
pkill bore 2>/dev/null; pkill ngrok 2>/dev/null; sleep 1

BORE_PORT=""
BORE_HOST="bore.pub"

# Thử từng port cố định 14445→14460
for TRY_PORT in 14445 14446 14447 14448 14449 14450 14451 14452 14453 14454 14455 14456 14457 14458 14459 14460; do
    rm -f /tmp/bore.log
    nohup bore local 14445 --to bore.pub --port $TRY_PORT > /tmp/bore.log 2>&1 &
    BORE_PID=$!
    sleep 4
    # Kiểm tra bore có lấy được port không
    if grep -q "listening at" /tmp/bore.log 2>/dev/null; then
        BORE_PORT=$(grep -oE 'bore\.pub:[0-9]+' /tmp/bore.log | head -1 | cut -d: -f2)
        if [ -n "$BORE_PORT" ]; then
            echo "✅ Bore tunnel: bore.pub:$BORE_PORT (local port: 14445)"
            break
        fi
    fi
    # Port bị chiếm, kill và thử port khác
    kill $BORE_PID 2>/dev/null
    pkill bore 2>/dev/null
    sleep 1
done

# Fallback: bore random port nếu tất cả port cố định bị chiếm
if [ -z "$BORE_PORT" ]; then
    echo "⚠️  Tất cả port cố định bị chiếm, dùng random port..."
    nohup bore local 14445 --to bore.pub > /tmp/bore.log 2>&1 &
    sleep 6
    BORE_PORT=$(grep -oE 'bore\.pub:[0-9]+' /tmp/bore.log | head -1 | cut -d: -f2)
fi

if [ -n "$BORE_PORT" ]; then
    echo "✅ Tunnel: $BORE_HOST:$BORE_PORT"
    sed -i "s/^server\.ip=.*/server.ip=$BORE_HOST/" "$SERVER_DIR/Config.properties"
    if grep -q "^server\.external_port=" "$SERVER_DIR/Config.properties"; then
        sed -i "s/^server\.external_port=.*/server.external_port=$BORE_PORT/" "$SERVER_DIR/Config.properties"
    else
        echo "server.external_port=$BORE_PORT" >> "$SERVER_DIR/Config.properties"
    fi
else
    BORE_PORT="14445"
    echo "⚠️  Không lấy được tunnel URL"
fi

# 4. Khởi động Java server (dùng named pipe thay /dev/null để tránh Scanner crash)
echo ">>> [4/5] Khởi động Java Game Server..."
cd "$SERVER_DIR"
pkill -f NgocRongOnline.jar 2>/dev/null; sleep 1

# Dùng named pipe thay /dev/null → Scanner.hasNextLine() block thay vì crash
rm -f /tmp/nro_stdin
mkfifo /tmp/nro_stdin

nohup java -server -Dfile.encoding=UTF-8 -Xmx512m -Xms256m \
    -jar NgocRongOnline.jar < /tmp/nro_stdin > /tmp/gameserver.log 2>&1 &
SERVER_PID=$!
sleep 6

# 5. Ghi IP+Port vào repo
echo ">>> [5/5] Ghi IP+Port vào repo..."
CONTENT_RAW="HOST=$BORE_HOST
PORT=$BORE_PORT
STATUS=RUNNING
UPDATED=$(date '+%Y-%m-%d %H:%M:%S UTC')"
CONTENT_B64=$(printf '%s' "$CONTENT_RAW" | base64 -w 0)
EXISTING_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//')
if [ -n "$EXISTING_SHA" ]; then
    PAYLOAD="{\"message\":\"Server IP: $BORE_HOST:$BORE_PORT [skip ci]\",\"content\":\"$CONTENT_B64\",\"sha\":\"$EXISTING_SHA\"}"
else
    PAYLOAD="{\"message\":\"Server IP: $BORE_HOST:$BORE_PORT [skip ci]\",\"content\":\"$CONTENT_B64\"}"
fi
RESULT=$(curl -s -X PUT \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
    -d "$PAYLOAD")
if echo "$RESULT" | grep -q '"content"'; then
    echo "✅ Đã ghi SERVER_IP.txt"
else
    echo "⚠️  Ghi repo thất bại"
fi

echo ""
if kill -0 $SERVER_PID 2>/dev/null; then
    echo "======================================"
    echo "  🎮 SERVER CHẠY THÀNH CÔNG!          "
    echo "  HOST : $BORE_HOST"
    echo "  PORT : $BORE_PORT  (APK kết nối cổng này)"
    echo "  BIND : 14445       (cổng cục bộ Java)"
    echo "======================================"
    echo ""
    echo "Đang theo dõi server log..."
    tail -f /tmp/gameserver.log
else
    echo "❌ Server lỗi! Log:"
    tail -50 /tmp/gameserver.log
fi
