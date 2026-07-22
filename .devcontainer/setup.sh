#!/bin/bash
set -e

echo "======================================"
echo "  SETUP NGOC RONG SERVER - CODESPACE  "
echo "======================================"

# 1. Cài packages cần thiết
echo ""
echo ">>> [1/4] Cài đặt packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq mariadb-server default-jdk curl wget 2>/dev/null
echo "✅ Packages OK"

# 2. Cài ngrok
echo ""
echo ">>> [2/4] Cài ngrok..."
curl -sLo /tmp/ngrok.tgz https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
sudo tar -xzf /tmp/ngrok.tgz -C /usr/local/bin/
ngrok config add-authtoken "3GctAUGxj43OBIHbY32ylzVsg6k_5uGajyhXwWXGeVWwtKEWw"
echo "✅ ngrok OK"

# 3. Cấu hình MariaDB để lắng nghe TCP port 3306
echo ""
echo ">>> [3/4] Cài đặt MySQL & import database..."

# FIX: Bật TCP listening cho MariaDB (mặc định chỉ dùng Unix socket)
MYSQL_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
if [ -f "$MYSQL_CONF" ]; then
    sudo sed -i 's/^skip-networking/#skip-networking/' "$MYSQL_CONF"
    if grep -q "^bind-address" "$MYSQL_CONF"; then
        sudo sed -i 's/^bind-address.*/bind-address = 127.0.0.1/' "$MYSQL_CONF"
    else
        echo "bind-address = 127.0.0.1" | sudo tee -a "$MYSQL_CONF" > /dev/null
    fi
else
    # Tạo config file nếu không tìm thấy file chính
    sudo mkdir -p /etc/mysql/conf.d
    echo -e "[mysqld]\nbind-address = 127.0.0.1\nskip-networking = 0" \
        | sudo tee /etc/mysql/conf.d/tcp-fix.cnf > /dev/null
fi

sudo service mariadb start
sleep 2

# Tạo DB và user (cả localhost và 127.0.0.1)
sudo mysql -e "CREATE DATABASE IF NOT EXISTS team2026 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mysql -e "CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED BY '';"
sudo mysql -e "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '';"
sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;"
sudo mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;"
sudo mysql -e "FLUSH PRIVILEGES;"

# Import database dump (dùng file đầy đủ hơn)
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$REPO_DIR/database team2026.sql" ]; then
    echo "  → Import database team2026.sql..."
    sudo mysql team2026 < "$REPO_DIR/database team2026.sql"
    echo "✅ Database imported từ: database team2026.sql"
elif [ -f "$REPO_DIR/SRC/sql/nro1.sql" ]; then
    echo "  → Import SRC/sql/nro1.sql..."
    sudo mysql team2026 < "$REPO_DIR/SRC/sql/nro1.sql"
    echo "✅ Database imported từ: SRC/sql/nro1.sql"
fi

# 4. Chuẩn bị thư mục server
echo ""
echo ">>> [4/4] Chuẩn bị server..."
mkdir -p ~/nro_server
cp -r "$REPO_DIR/SRC/dist/." ~/nro_server/
cp -r "$REPO_DIR/SRC/data" ~/nro_server/ 2>/dev/null || true
cp "$REPO_DIR/SRC/Config.properties" ~/nro_server/
echo "✅ Server files sẵn sàng tại ~/nro_server"

echo ""
echo "======================================"
echo "  ✅ SETUP HOÀN TẤT!                 "
echo "  Chạy: bash start.sh để khởi động   "
echo "======================================"
