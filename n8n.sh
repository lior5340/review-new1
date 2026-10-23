#!/usr/bin/env bash
# התקנת n8n על שרת Hetzner – eBath / BathMall
# שימוש: להתחבר לשרת (ssh root@IP), להדביק את כל הקובץ הזה ולהקיש Enter.
set -euo pipefail

DOMAIN="n8n.designhouse.co.il"     # הכתובת של n8n – אפשר לשנות לפני ההרצה
TZ_NAME="Asia/Jerusalem"
DATA_DIR="/opt/n8n"

say(){ echo -e "\n=== $* ==="; }

say "בדיקה אם n8n כבר מותקן"
if (command -v docker >/dev/null && docker ps -a --format '{{.Image}} {{.Names}}' | grep -qi n8n) \
   || systemctl list-units --all 2>/dev/null | grep -qi n8n \
   || (command -v ss >/dev/null && ss -ltn | grep -q ':5678 '); then
  echo "n8n כבר קיים על השרת. לא מתקינים שוב."
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -i n8n || true
  exit 0
fi

say "התקנת Docker (אם חסר)"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh || (apt-get update && apt-get install -y docker.io)
fi
systemctl enable --now docker

say "יצירת תיקיית נתונים ומפתח הצפנה"
mkdir -p "$DATA_DIR/data"
chown -R 1000:1000 "$DATA_DIR/data"
if [ ! -f "$DATA_DIR/.key" ]; then openssl rand -hex 32 > "$DATA_DIR/.key"; chmod 600 "$DATA_DIR/.key"; fi
KEY=$(cat "$DATA_DIR/.key")

say "הפעלת n8n (פתוח רק בתוך השרת, פורט 5678)"
docker run -d --name n8n --restart unless-stopped \
  -p 127.0.0.1:5678:5678 \
  -v "$DATA_DIR/data":/home/node/.n8n \
  -e N8N_HOST="$DOMAIN" -e N8N_PROTOCOL=https -e N8N_PORT=5678 \
  -e WEBHOOK_URL="https://$DOMAIN/" \
  -e GENERIC_TIMEZONE="$TZ_NAME" -e TZ="$TZ_NAME" \
  -e N8N_ENCRYPTION_KEY="$KEY" \
  -e N8N_SECURE_COOKIE=true -e N8N_DIAGNOSTICS_ENABLED=false \
  docker.n8n.io/n8nio/n8n:latest

say "חיבור הכתובת המאובטחת (HTTPS)"
if command -v nginx >/dev/null && systemctl is-active --quiet nginx; then
  echo "נמצא nginx פעיל – מוסיף אתר עבור $DOMAIN"
  cat > /etc/nginx/sites-available/n8n <<NGX
server {
  listen 80;
  server_name $DOMAIN;
  client_max_body_size 50m;
  location / {
    proxy_pass http://127.0.0.1:5678;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_buffering off;
  }
}
NGX
  ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
  nginx -t && systemctl reload nginx
  command -v certbot >/dev/null || (apt-get update && apt-get install -y certbot python3-certbot-nginx)
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"${DOMAIN#*.}" --redirect || echo "!! תעודת SSL לא הונפקה – בדוק שרשומת ה-DNS של $DOMAIN מצביעה לשרת והרץ: certbot --nginx -d $DOMAIN"
elif command -v caddy >/dev/null && systemctl is-active --quiet caddy; then
  echo "נמצא Caddy פעיל – מוסיף את $DOMAIN לקובץ ההגדרות"
  printf '\n%s {\n  reverse_proxy 127.0.0.1:5678\n}\n' "$DOMAIN" >> /etc/caddy/Caddyfile
  systemctl reload caddy
elif ! (ss -ltn | grep -qE ':(80|443) '); then
  echo "פורטים 80/443 פנויים – מפעיל Caddy בקונטיינר עם SSL אוטומטי"
  mkdir -p "$DATA_DIR/caddy"
  printf '%s {\n  reverse_proxy 127.0.0.1:5678\n}\n' "$DOMAIN" > "$DATA_DIR/caddy/Caddyfile"
  docker run -d --name n8n-caddy --restart unless-stopped --network host \
    -v "$DATA_DIR/caddy/Caddyfile":/etc/caddy/Caddyfile \
    -v "$DATA_DIR/caddy/data":/data caddy:2
else
  echo "!! פורט 80/443 תפוס על ידי שירות אחר שאינו nginx/Caddy."
  echo "!! n8n רץ, אבל צריך לחבר את $DOMAIN ידנית ל-127.0.0.1:5678. שלח לי את הפלט של: ss -ltnp | grep -E ':(80|443) '"
fi

say "סיום"
IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
echo "n8n מותקן. כתובת: https://$DOMAIN"
echo "רשומת DNS נדרשת: A  ${DOMAIN%%.*}  ->  $IP"
echo "חשוב: להיכנס לכתובת מיד וליצור את חשבון הבעלים (המשתמש הראשון שנרשם הוא המנהל)."
echo "גיבוי: כל הנתונים נמצאים ב-$DATA_DIR – מפתח ההצפנה ב-$DATA_DIR/.key (לשמור במקום בטוח)."
