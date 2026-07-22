#!/bin/bash

echo "======================================"
echo "   KHỞI ĐỘNG NGOC RONG SERVER         "
echo "======================================"

# Dùng GITHUB_TOKEN có sẵn trong Codespace (không hardcode)
REPO="kgxxyixgikcgxittixxi-collab/rem5"
SERVER_DIR=~/nro_server
WORKSPACE_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Khởi động MySQL
echo ">>> [1/4] Khởi động MySQL..."
sudo service mariadb start 2>/dev/null || sudo service mysql start 2>/dev/null || true
sleep 2
echo "✅ MySQL OK"

# Import database nếu chưa có
DB_EXISTS=$(sudo mysql -e "SHOW DATABASES LIKE 'team2026';" 2>/dev/null | grep team2026 || true)
if [ -z "$DB_EXISTS" ]; then
    echo ">>> Import database lần đầu..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS team2026 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;" 2>/dev/null || true
    if [ -f "$WORKSPACE_DIR/database team2026.sql" ]; then
        sudo mysql team2026 < "$WORKSPACE_DIR/database team2026.sql" && echo "✅ DB imported"
    elif [ -f "$WORKSPACE_DIR/SRC/sql/nro1.sql" ]; then
        sudo mysql team2026 < "$WORKSPACE_DIR/SRC/sql/nro1.sql" && echo "✅ DB imported"
    fi
fi

# Chuẩn bị server files lần đầu
if [ ! -f "$SERVER_DIR/NgocRongOnline.jar" ]; then
    echo ">>> Copy server files lần đầu..."
    mkdir -p ~/nro_server
    cp -r "$WORKSPACE_DIR/SRC/dist/." ~/nro_server/
    cp -r "$WORKSPACE_DIR/SRC/data" ~/nro_server/ 2>/dev/null || true
    cp "$WORKSPACE_DIR/SRC/Config.properties" ~/nro_server/
fi

# 2. Khởi động ngrok
echo ">>> [2/4] Khởi động ngrok (port 14445)..."
pkill ngrok 2>/dev/null; sleep 1
nohup ngrok tcp 14445 --log=stdout > /tmp/ngrok.log 2>&1 &
sleep 6

NGROK_URL=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null \
    | grep -o '"public_url":"tcp://[^"]*"' | head -1 \
    | sed 's/"public_url":"tcp:\/\///;s/"//')
NGROK_HOST=$(echo "$NGROK_URL" | cut -d: -f1)
NGROK_PORT=$(echo "$NGROK_URL" | cut -d: -f2)

if [ -n "$NGROK_HOST" ]; then
    echo "✅ ngrok: $NGROK_HOST:$NGROK_PORT"
    sed -i "s/^server\.ip=.*/server.ip=$NGROK_HOST/" "$SERVER_DIR/Config.properties"
    sed -i "s/^server\.port=.*/server.port=$NGROK_PORT/" "$SERVER_DIR/Config.properties"
else
    NGROK_HOST="CHUA_CO"
    NGROK_PORT="14445"
    echo "⚠️  Không lấy được ngrok URL"
fi

# 3. Khởi động Java server
echo ">>> [3/4] Khởi động Java Game Server..."
cd "$SERVER_DIR"
pkill -f NgocRongOnline.jar 2>/dev/null; sleep 1
nohup java -server -Dfile.encoding=UTF-8 -Xmx512m -Xms256m \
    -jar NgocRongOnline.jar > /tmp/gameserver.log 2>&1 &
SERVER_PID=$!
sleep 4

# 4. Ghi IP+Port vào SERVER_IP.txt trong repo (dùng GITHUB_TOKEN của Codespace)
echo ">>> [4/4] Ghi IP+Port vào repo..."
if [ -n "$GITHUB_TOKEN" ]; then
    CONTENT_RAW="HOST=$NGROK_HOST
PORT=$NGROK_PORT
STATUS=RUNNING
UPDATED=$(date '+%Y-%m-%d %H:%M:%S UTC')"

    CONTENT_B64=$(printf '%s' "$CONTENT_RAW" | base64 -w 0)

    EXISTING_SHA=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
        | grep -o '"sha":"[^"]*"' | head -1 | sed 's/"sha":"//;s/"//')

    if [ -n "$EXISTING_SHA" ]; then
        PAYLOAD="{\"message\":\"Update server IP\",\"content\":\"$CONTENT_B64\",\"sha\":\"$EXISTING_SHA\"}"
    else
        PAYLOAD="{\"message\":\"Add server IP\",\"content\":\"$CONTENT_B64\"}"
    fi

    RESULT=$(curl -s -X PUT \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$REPO/contents/SERVER_IP.txt" \
        -d "$PAYLOAD")

    if echo "$RESULT" | grep -q '"content"'; then
        echo "✅ Đã ghi SERVER_IP.txt vào repo"
    else
        # Fallback: dùng git push thẳng
        cd "$WORKSPACE_DIR"
        echo "$CONTENT_RAW" > SERVER_IP.txt
        git config user.email "server@nro.local"
        git config user.name "NRO Server"
        git add SERVER_IP.txt
        git commit -m "Update server IP [skip ci]" 2>/dev/null || true
        git push 2>/dev/null && echo "✅ Pushed SERVER_IP.txt" || echo "⚠️  Push thất bại"
    fi
else
    echo "⚠️  GITHUB_TOKEN không có, bỏ qua bước ghi repo"
    echo "HOST=$NGROK_HOST PORT=$NGROK_PORT" > /tmp/server_ip.txt
fi

echo ""
if kill -0 $SERVER_PID 2>/dev/null; then
    echo "======================================"
    echo "  🎮 SERVER CHẠY THÀNH CÔNG!          "
    echo "  HOST : $NGROK_HOST"
    echo "  PORT : $NGROK_PORT"
    echo "======================================"
else
    echo "❌ Server lỗi! Log:"
    tail -30 /tmp/gameserver.log
fi
