#!/bin/bash

echo "======================================"
echo "   KHỞI ĐỘNG NGOC RONG SERVER         "
echo "======================================"

SERVER_DIR=~/nro_server

# 1. Khởi động MySQL
echo ""
echo ">>> [1/3] Khởi động MySQL..."
sudo service mariadb start 2>/dev/null || sudo service mysql start 2>/dev/null || true
sleep 2
echo "✅ MySQL OK"

# 2. Lấy IP public qua ngrok và cập nhật Config
echo ""
echo ">>> [2/3] Khởi động ngrok tunnel (port 14445)..."
pkill ngrok 2>/dev/null || true
sleep 1
nohup ngrok tcp 14445 --log=stdout > /tmp/ngrok.log 2>&1 &
sleep 4

# Lấy địa chỉ public từ ngrok API
NGROK_URL=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null \
    | grep -o '"public_url":"[^"]*"' | head -1 \
    | sed 's/"public_url":"//;s/"//' \
    | sed 's|tcp://||')

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

# 3. Khởi động Java server
echo ""
echo ">>> [3/3] Khởi động Java Game Server..."
cd "$SERVER_DIR"
pkill -f NgocRongOnline.jar 2>/dev/null || true
sleep 1

nohup java -server -Dfile.encoding=UTF-8 -Xmx512m -Xms256m \
    -jar NgocRongOnline.jar > /tmp/gameserver.log 2>&1 &
SERVER_PID=$!

echo "✅ Server đang chạy (PID: $SERVER_PID)"
sleep 3

# Kiểm tra server có chạy không
if kill -0 $SERVER_PID 2>/dev/null; then
    echo ""
    echo "======================================"
    echo "  🎮 SERVER ĐÃ CHẠY THÀNH CÔNG!      "
    echo "======================================"
    if [ -n "$NGROK_URL" ]; then
        echo "  📡 Địa chỉ kết nối game:"
        echo "     Host: $NGROK_HOST"
        echo "     Port: $NGROK_PORT"
    else
        echo "  📡 Port local: 14445"
    fi
    echo ""
    echo "  📋 Xem log server: tail -f /tmp/gameserver.log"
    echo "  📋 Xem log ngrok:  tail -f /tmp/ngrok.log"
    echo "======================================"
else
    echo ""
    echo "❌ Server bị lỗi! Xem log:"
    tail -20 /tmp/gameserver.log
fi
