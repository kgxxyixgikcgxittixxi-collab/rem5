#!/bin/bash

echo "======================================"
echo "   KHỞI ĐỘNG NGOC RONG SERVER         "
echo "======================================"

SERVER_DIR=~/nro_server

# 1. Khởi động MySQL
echo ""
echo ">>> [1/4] Khởi động MySQL..."
sudo service mariadb start 2>/dev/null || sudo service mysql start 2>/dev/null || true
sleep 2
echo "✅ MySQL OK"

# 2. Kiểm tra server files, nếu chưa có thì copy
if [ ! -f "$SERVER_DIR/NgocRongOnline.jar" ]; then
    echo ">>> Lần đầu chạy - copy server files..."
    REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
    mkdir -p ~/nro_server
    cp -r "$REPO_DIR/SRC/dist/." ~/nro_server/
    cp -r "$REPO_DIR/SRC/data" ~/nro_server/ 2>/dev/null || true
    cp "$REPO_DIR/SRC/Config.properties" ~/nro_server/
fi

# 3. Khởi động ngrok tunnel
echo ""
echo ">>> [2/4] Khởi động ngrok tunnel (port 14445)..."
pkill ngrok 2>/dev/null || true
sleep 1
nohup ngrok tcp 14445 --log=stdout > /tmp/ngrok.log 2>&1 &
sleep 5

# Lấy địa chỉ public từ ngrok API
NGROK_URL=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null \
    | grep -o '"public_url":"[^"]*"' | head -1 \
    | sed 's/"public_url":"//;s/"//' \
    | sed 's|tcp://||')

NGROK_HOST=""
NGROK_PORT="14445"

if [ -n "$NGROK_URL" ]; then
    NGROK_HOST=$(echo "$NGROK_URL" | cut -d: -f1)
    NGROK_PORT=$(echo "$NGROK_URL" | cut -d: -f2)
    echo "✅ ngrok tunnel: $NGROK_HOST:$NGROK_PORT"
    # Cập nhật IP và port vào Config.properties
    sed -i "s/^server.ip=.*/server.ip=$NGROK_HOST/" "$SERVER_DIR/Config.properties"
    sed -i "s/^server.port=.*/server.port=$NGROK_PORT/" "$SERVER_DIR/Config.properties"
else
    echo "⚠️  Không lấy được ngrok URL, dùng port mặc định 14445"
fi

# 4. Khởi động Java server
echo ""
echo ">>> [3/4] Khởi động Java Game Server..."
cd "$SERVER_DIR"
pkill -f NgocRongOnline.jar 2>/dev/null || true
sleep 1

nohup java -server -Dfile.encoding=UTF-8 -Xmx512m -Xms256m \
    -jar NgocRongOnline.jar > /tmp/gameserver.log 2>&1 &
SERVER_PID=$!
sleep 4

# 5. Đăng IP/Port lên GitHub Gist để lấy từ ngoài
echo ""
echo ">>> [4/4] Đăng IP+Port lên Gist..."
if [ -n "$GITHUB_TOKEN" ] && [ -n "$NGROK_HOST" ]; then
    GIST_CONTENT="HOST=$NGROK_HOST\nPORT=$NGROK_PORT\nUPDATED=$(date '+%Y-%m-%d %H:%M:%S')"
    curl -s -X POST \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      https://api.github.com/gists \
      -d "{\"public\":true,\"description\":\"NRO Server IP Port\",\"files\":{\"nro_server.txt\":{\"content\":\"$GIST_CONTENT\"}}}" \
      > /tmp/gist_response.json
    GIST_URL=$(grep -o '"html_url":"[^"]*"' /tmp/gist_response.json | head -1 | sed 's/"html_url":"//;s/"//')
    GIST_ID=$(grep -o '"id":"[^"]*"' /tmp/gist_response.json | head -1 | sed 's/"id":"//;s/"//')
    echo "$GIST_ID" > /tmp/gist_id.txt
    echo "✅ Đã đăng lên Gist: $GIST_URL"
fi

# Kết quả
if kill -0 $SERVER_PID 2>/dev/null; then
    echo ""
    echo "======================================"
    echo "  🎮 SERVER CHẠY THÀNH CÔNG!          "
    echo "======================================"
    echo "  📡 HOST : $NGROK_HOST"
    echo "  📡 PORT : $NGROK_PORT"
    echo "======================================"
    echo "  tail -f /tmp/gameserver.log"
    echo "======================================"
else
    echo ""
    echo "❌ Server lỗi! Log:"
    tail -30 /tmp/gameserver.log
fi
