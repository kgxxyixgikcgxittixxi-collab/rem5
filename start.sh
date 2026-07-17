#!/bin/bash
LOG=~/logs
mkdir -p $LOG

echo "[1] Khởi động MariaDB..."
sudo service mariadb start 2>/dev/null || true
sleep 3
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY ''; FLUSH PRIVILEGES;" 2>/dev/null || true

echo "[2] Import database..."
SQL=$(find ~/nro -name "*.sql" 2>/dev/null | head -1)
if [ -n "$SQL" ]; then
  DBNAME=$(basename "$SQL" .sql)
  sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$DBNAME\` CHARACTER SET utf8mb4;" 2>/dev/null || true
  sudo mysql "$DBNAME" < "$SQL" 2>/dev/null && echo "✅ DB: $DBNAME" || echo "DB đã có"
fi

echo "[3] Cập nhật config..."
CFG=$(find ~/nro -name "Config.properties" 2>/dev/null | head -1)
if [ -n "$CFG" ]; then
  sed -i "s|database.pass=.*|database.pass=|g" "$CFG"
  sed -i "s|database.user=.*|database.user=root|g" "$CFG"
  sed -i "s|server.local=.*|server.local=true|g" "$CFG"
fi

echo "[4] Chạy Java server..."
JAR=$(find ~/nro -name "*.jar" | grep -viE "login|Login|lib/" | head -1)
JAR_LOGIN=$(find ~/nro -name "*.jar" | grep -iE "login" | head -1)
LIB=$(find ~/nro -name "lib" -type d | head -1)
echo "  JAR game : $JAR"
echo "  JAR login: $JAR_LOGIN"

if [ -n "$JAR_LOGIN" ]; then
  SDIR=$(dirname "$JAR_LOGIN")
  CP="$(basename $JAR_LOGIN)"; [ -n "$LIB" ] && CP="$CP:$LIB/*"
  cd "$SDIR"
  nohup java -Xms128m -Xmx512m -cp "$CP" Main > $LOG/login.log 2>&1 &
  echo "✅ Login server PID: $!"
  sleep 2
fi

if [ -n "$JAR" ]; then
  SDIR=$(dirname "$JAR")
  CP="$(basename $JAR)"; [ -n "$LIB" ] && CP="$CP:$LIB/*"
  cd "$SDIR"
  nohup java -Xms256m -Xmx1g -cp "$CP" Main > $LOG/server.log 2>&1 &
  echo "✅ Game server PID: $!"
  sleep 5
fi

echo "[5] Mở ngrok tunnel port 14445..."
pkill ngrok 2>/dev/null || true
nohup ngrok tcp 14445 > $LOG/ngrok.log 2>&1 &
sleep 6

NGROK=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | \
  grep -o '"public_url":"tcp://[^"]*"' | cut -d'"' -f4)
HOST=$(echo $NGROK | cut -d: -f2 | tr -d '/')
PORT=$(echo $NGROK | cut -d: -f3)

echo ""
echo "╔══════════════════════════════════════════╗"
echo "  ✅  NGOC RONG SERVER ONLINE"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  🌐 IP   : $HOST"
echo "  🔌 Port : $PORT"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Điền vào game: IP=$HOST  Port=$PORT"
echo "╚══════════════════════════════════════════╝"

# Ghi ra file để đọc sau
echo "$NGROK" > /tmp/server_addr.txt
tail -f $LOG/server.log
