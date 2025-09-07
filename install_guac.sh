#!/bin/bash
set -euo pipefail

# Colors
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

GUACVERSION="1.5.5"
GUAC_USER="guacamole_user"
GUAC_DB="guacamole_db"
TOMCAT_VER=9.0.109
CRED_FILE="/root/guacamole-credentials.txt"

# --- Parameters (env, interactive, or reverse DNS fallback) ---
SERVER_NAME=${SERVER_NAME:-}

if [ -z "$SERVER_NAME" ]; then
  if [ -t 0 ]; then
    while true; do
      read -p "Enter server name (FQDN) for Nginx/Let's Encrypt (e.g. guac.example.com): " SERVER_NAME
      [ -n "$SERVER_NAME" ] && break
      echo -e "${RED}Server name cannot be empty!${NC}"
    done
  else
    echo -e "${YELLOW}No SERVER_NAME provided, running non-interactively...${NC}"
    PUBIP=$(curl -s ifconfig.me || echo "")
    if [ -n "$PUBIP" ]; then
      if command -v dig >/dev/null 2>&1; then
        REVNAME=$(dig +short -x $PUBIP 2>/dev/null | sed 's/\.$//' || true)
      else
        REVNAME=$(host $PUBIP 2>/dev/null | awk '{print $5}' | sed 's/\.$//' || true)
      fi
      if [ -n "$REVNAME" ]; then
        SERVER_NAME=$REVNAME
        echo -e "${GREEN}Using reverse DNS for server name: ${SERVER_NAME}${NC}"
      else
        SERVER_NAME=$PUBIP
        echo -e "${YELLOW}No reverse DNS found, using IP: ${SERVER_NAME}${NC}"
      fi
    else
      echo -e "${RED}Unable to detect public IP. Please set SERVER_NAME explicitly.${NC}"
      exit 1
    fi
  fi
fi

MYSQL_ROOT_PWD=${MYSQL_ROOT_PWD:-$(openssl rand -base64 20)}
GUAC_PWD=${GUAC_PWD:-$(openssl rand -base64 20)}
GUACADMIN_PWD=${GUACADMIN_PWD:-$(openssl rand -base64 20)}

# --- Base packages ---
echo -e "${BLUE}>>> Installing base packages...${NC}"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -yq \
    xfce4 xfce4-goodies tightvncserver ufw curl wget zsh firefox dnsutils \
    build-essential libjpeg-turbo8-dev libpng-dev libossp-uuid-dev \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    freerdp2-dev libpango1.0-dev libssh2-1-dev libtelnet-dev \
    libvncserver-dev libpulse-dev libssl-dev libvorbis-dev libwebp-dev \
    libwebsockets-dev freerdp2-x11 libtool-bin ghostscript dpkg-dev crudini \
    mariadb-server mariadb-client nginx certbot python3-certbot-nginx openssl

# --- Java ---
if ! command -v java >/dev/null 2>&1; then
  apt-get install -y openjdk-17-jre-headless
fi
JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
echo -e "${GREEN}JAVA_HOME detected as ${JAVA_HOME}${NC}"

# --- Firewall ---
ufw --force enable
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw reload

# --- Tomcat 9 ---
if [ ! -d /opt/apache-tomcat-${TOMCAT_VER} ]; then
  echo -e "${BLUE}>>> Installing Tomcat ${TOMCAT_VER}...${NC}"
  cd /opt
  wget -q https://downloads.apache.org/tomcat/tomcat-9/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz
  tar -xzf apache-tomcat-${TOMCAT_VER}.tar.gz
  ln -sfn apache-tomcat-${TOMCAT_VER} tomcat9
  useradd -r -s /usr/sbin/nologin tomcat || true
  chown -R tomcat:tomcat /opt/apache-tomcat-${TOMCAT_VER}
  cat > /etc/systemd/system/tomcat9.service <<EOF
[Unit]
Description=Apache Tomcat 9
After=network.target

[Service]
Type=simple
User=tomcat
Group=tomcat
Environment=JAVA_HOME=${JAVA_HOME}
Environment=CATALINA_HOME=/opt/tomcat9
Environment=CATALINA_BASE=/opt/tomcat9
ExecStart=/opt/tomcat9/bin/catalina.sh run
ExecStop=/opt/tomcat9/bin/catalina.sh stop
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
fi
systemctl daemon-reload
systemctl enable --now tomcat9

# --- Guacamole ---
cd /root
SERVER="https://downloads.apache.org/guacamole/${GUACVERSION}"

if [ ! -d guacamole-server-${GUACVERSION} ]; then
  wget -q ${SERVER}/source/guacamole-server-${GUACVERSION}.tar.gz
  tar -xzf guacamole-server-${GUACVERSION}.tar.gz
  wget -q ${SERVER}/binary/guacamole-${GUACVERSION}.war -O /etc/guacamole.war
  wget -q ${SERVER}/binary/guacamole-auth-jdbc-${GUACVERSION}.tar.gz
  tar -xzf guacamole-auth-jdbc-${GUACVERSION}.tar.gz
fi

if ! command -v guacd >/dev/null 2>&1; then
  cd guacamole-server-${GUACVERSION}
  ./configure --with-systemd-dir=/etc/systemd/system
  make -j$(nproc)
  make install
  ldconfig
  cd ..
fi

if [ ! -f /etc/systemd/system/guacd.service ]; then
  cat > /etc/systemd/system/guacd.service <<EOF
[Unit]
Description=Guacamole proxy daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/guacd -f
User=daemon
Group=daemon

[Install]
WantedBy=multi-user.target
EOF
fi
systemctl daemon-reload
systemctl enable --now guacd

mkdir -p /etc/guacamole/extensions /etc/guacamole/lib
cp /etc/guacamole.war /opt/tomcat9/webapps/guacamole.war
cp guacamole-auth-jdbc-${GUACVERSION}/mysql/guacamole-auth-jdbc-mysql-${GUACVERSION}.jar /etc/guacamole/extensions/

# --- MySQL setup ---
echo -e "${BLUE}>>> Setting up MySQL database...${NC}"
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PWD}';
EOF

if ! mysql -u root -p${MYSQL_ROOT_PWD} -e "USE ${GUAC_DB}" 2>/dev/null; then
  mysql -u root -p${MYSQL_ROOT_PWD} -e "CREATE DATABASE ${GUAC_DB};"
fi

USER_EXISTS=$(mysql -u root -p${MYSQL_ROOT_PWD} -e "SELECT COUNT(*) FROM mysql.user WHERE user='${GUAC_USER}';" -s --skip-column-names)
if [ "$USER_EXISTS" -eq 0 ]; then
  mysql -u root -p${MYSQL_ROOT_PWD} -e "CREATE USER '${GUAC_USER}'@'localhost' IDENTIFIED BY '${GUAC_PWD}';"
  mysql -u root -p${MYSQL_ROOT_PWD} -e "GRANT SELECT,INSERT,UPDATE,DELETE ON ${GUAC_DB}.* TO '${GUAC_USER}'@'localhost'; FLUSH PRIVILEGES;"
fi

if ! mysql -u root -p${MYSQL_ROOT_PWD} -D ${GUAC_DB} -e "SHOW TABLES;" | grep -q guacamole_user; then
  cat guacamole-auth-jdbc-${GUACVERSION}/mysql/schema/*.sql | mysql -u root -p${MYSQL_ROOT_PWD} ${GUAC_DB}
fi

mkdir -p /etc/guacamole
cat > /etc/guacamole/guacamole.properties <<EOF
mysql-hostname: localhost
mysql-port: 3306
mysql-database: ${GUAC_DB}
mysql-username: ${GUAC_USER}
mysql-password: ${GUAC_PWD}
EOF

# --- Reset guacadmin password (schema compatibility) ---
if mysql -u root -p${MYSQL_ROOT_PWD} ${GUAC_DB} -e "SHOW COLUMNS FROM guacamole_user LIKE 'username';" | grep -q username; then
  COL="username"
else
  COL="user_id"
fi
HASHED=$(echo -n "${GUACADMIN_PWD}" | openssl md5 | awk '{print $2}')
mysql -u root -p${MYSQL_ROOT_PWD} ${GUAC_DB} -e "UPDATE guacamole_user SET password='${HASHED}' WHERE ${COL}='guacadmin';"

systemctl restart tomcat9

# --- Chrome + Tampermonkey ---
if ! command -v google-chrome >/dev/null 2>&1; then
  ARCH=$(dpkg --print-architecture)
  if [ "$ARCH" = "amd64" ]; then
    CHROME_DEB="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  elif [ "$ARCH" = "arm64" ]; then
    CHROME_DEB="https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb"
  fi
  TMP_DEB="/tmp/chrome.deb"
  wget -q -O "$TMP_DEB" "$CHROME_DEB"
  dpkg -i "$TMP_DEB" || apt-get install -f -y
  rm -f "$TMP_DEB"
fi

EXT_ID="dhdgffkkebhmkfjojejmpbldmpobfkfo"
EXT_DIR="/opt/google/chrome/extensions"
mkdir -p "$EXT_DIR"
cat > "$EXT_DIR/$EXT_ID.json" <<EOF
{
  "external_update_url": "https://clients2.google.com/service/update2/crx"
}
EOF

# --- Nginx reverse proxy ---
cat > /etc/nginx/sites-available/guacamole <<EOF
server {
    listen 80;
    server_name ${SERVER_NAME};

    location / {
        proxy_pass http://127.0.0.1:8080/guacamole/;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_cookie_path /guacamole/ /;
    }
}
EOF
ln -sf /etc/nginx/sites-available/guacamole /etc/nginx/sites-enabled/guacamole
nginx -t && systemctl reload nginx

# --- Let's Encrypt with fallback ---
if certbot --nginx -d ${SERVER_NAME} --non-interactive --agree-tos -m admin@${SERVER_NAME} --redirect; then
  echo -e "${GREEN}Let's Encrypt certificate installed successfully.${NC}"
else
  mkdir -p /etc/ssl/selfsigned
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/selfsigned/guac.key \
    -out /etc/ssl/selfsigned/guac.crt \
    -subj "/CN=${SERVER_NAME}"
  cat > /etc/nginx/sites-available/guacamole <<EOF
server {
    listen 80;
    server_name ${SERVER_NAME};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${SERVER_NAME};
    ssl_certificate /etc/ssl/selfsigned/guac.crt;
    ssl_certificate_key /etc/ssl/selfsigned/guac.key;

    location / {
        proxy_pass http://127.0.0.1:8080/guacamole/;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_cookie_path /guacamole/ /;
    }
}
EOF
  nginx -t && systemctl reload nginx
fi

# --- Tailscale ---
echo -e "${BLUE}>>> Installing Tailscale...${NC}"
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

if [ -t 0 ]; then
  read -p "Enter Tailscale auth key (leave blank for interactive login): " TSKEY || true
else
  TSKEY=""
fi

if [ -n "${TSKEY:-}" ]; then
  tailscale up --authkey=${TSKEY} --ssh
else
  tailscale up --ssh
fi

# --- Save credentials ---
cat > ${CRED_FILE} <<EOF
Guacamole admin login:
   User: guacadmin
   Pass: ${GUACADMIN_PWD}

MySQL root password:
   ${MYSQL_ROOT_PWD}

MySQL guacamole user (${GUAC_USER}) password:
   ${GUAC_PWD}

Server name:
   ${SERVER_NAME}
EOF
chmod 600 ${CRED_FILE}

# --- Final info ---
IP=$(curl -s ifconfig.me || echo "localhost")
echo -e "${GREEN}=========================================================${NC}"
echo -e "Guacamole is now running behind Nginx."
echo -e "URL:  https://${SERVER_NAME}/"
echo -e "Alt:  https://${IP}/"
echo -e "Login: guacadmin / ${GUACADMIN_PWD}"
echo -e "MySQL root password:   ${MYSQL_ROOT_PWD}"
echo -e "MySQL guac user pass:  ${GUAC_PWD}"
echo -e "Credentials saved in:  ${CRED_FILE}"
echo -e "${RED}*** Save them securely! ***${NC}"
echo -e "${GREEN}=========================================================${NC}"
