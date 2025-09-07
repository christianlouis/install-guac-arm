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

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# --- Interactive prompts ---
read -p "Enter MySQL root password [default: password]: " MYSQL_ROOT_PWD
MYSQL_ROOT_PWD=${MYSQL_ROOT_PWD:-password}

read -p "Enter Guacamole DB user password [default: password]: " GUAC_PWD
GUAC_PWD=${GUAC_PWD:-password}

read -p "Enter server name (FQDN) for Nginx (e.g. guac.example.com): " SERVER_NAME
if [ -z "$SERVER_NAME" ]; then
  echo -e "${RED}Server name is required for Nginx reverse proxy${NC}"
  exit 1
fi

# --- Base packages ---
echo -e "${BLUE}>>> Installing base packages...${NC}"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -yq \
    xfce4 xfce4-goodies tightvncserver ufw curl wget zsh firefox \
    build-essential libjpeg-turbo8-dev libpng-dev libossp-uuid-dev \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    freerdp2-dev libpango1.0-dev libssh2-1-dev libtelnet-dev \
    libvncserver-dev libpulse-dev libssl-dev libvorbis-dev libwebp-dev \
    libwebsockets-dev freerdp2-x11 libtool-bin ghostscript dpkg-dev crudini \
    mariadb-server mariadb-client nginx

# --- Java ---
if ! command -v java >/dev/null 2>&1; then
  apt-get install -y openjdk-17-jre-headless
fi
JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
echo -e "${GREEN}JAVA_HOME detected as ${JAVA_HOME}${NC}"

# --- Firewall ---
echo -e "${BLUE}>>> Configuring UFW...${NC}"
ufw --force enable
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw reload

# --- VNC ---
if [ ! -f "$HOME/.vnc/xstartup" ]; then
  echo -e "${BLUE}>>> Configuring VNC server...${NC}"
  umask 0077
  mkdir -p "$HOME/.vnc"
  vncpasswd -f <<<"password" >"$HOME/.vnc/passwd"
  vncserver || true
  sleep 2 && vncserver -kill :1 || true
  cat > ~/.vnc/xstartup <<EOF
#!/bin/bash
xrdb \$HOME/.Xresources
startxfce4 &
EOF
  chmod +x ~/.vnc/xstartup
fi

if [ ! -f /etc/systemd/system/vncserver@.service ]; then
  cat > /etc/systemd/system/vncserver@.service <<EOF
[Unit]
Description=Start TightVNC server at startup
After=syslog.target network.target
[Service]
Type=forking
User=root
Group=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1280x800 -localhost :%i
ExecStop=/usr/bin/vncserver -kill :%i
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vncserver@1.service
fi
systemctl restart vncserver@1 || true

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

# Download if missing
if [ ! -d guacamole-server-${GUACVERSION} ]; then
  wget -q ${SERVER}/source/guacamole-server-${GUACVERSION}.tar.gz
  tar -xzf guacamole-server-${GUACVERSION}.tar.gz
  wget -q ${SERVER}/binary/guacamole-${GUACVERSION}.war -O /etc/guacamole.war
  wget -q ${SERVER}/binary/guacamole-auth-jdbc-${GUACVERSION}.tar.gz
  tar -xzf guacamole-auth-jdbc-${GUACVERSION}.tar.gz
fi

# Build guacd if not present
if ! command -v guacd >/dev/null 2>&1; then
  cd guacamole-server-${GUACVERSION}
  ./configure --with-systemd-dir=/etc/systemd/system
  make -j$(nproc)
  make install
  ldconfig
  cd ..
fi

# guacd service
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

# Deploy webapp + extensions
mkdir -p /etc/guacamole/extensions /etc/guacamole/lib
cp /etc/guacamole.war /opt/tomcat9/webapps/guacamole.war
cp guacamole-auth-jdbc-${GUACVERSION}/mysql/guacamole-auth-jdbc-mysql-${GUACVERSION}.jar /etc/guacamole/extensions/

# MySQL setup (non-destructive)
echo -e "${BLUE}>>> Setting up MySQL database...${NC}"
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

systemctl restart tomcat9

# --- Chrome ---
if ! command -v google-chrome >/dev/null 2>&1; then
  echo -e "${BLUE}>>> Installing Google Chrome...${NC}"
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

# --- Tampermonkey ---
EXT_ID="dhdgffkkebhmkfjojejmpbldmpobfkfo"
EXT_DIR="/opt/google/chrome/extensions"
if [ ! -f "$EXT_DIR/$EXT_ID.json" ]; then
  mkdir -p "$EXT_DIR"
  cat > "$EXT_DIR/$EXT_ID.json" <<EOF
{
  "external_update_url": "https://clients2.google.com/service/update2/crx"
}
EOF
fi

# --- Nginx reverse proxy ---
echo -e "${BLUE}>>> Configuring Nginx reverse proxy...${NC}"
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
nginx -t && systemctl restart nginx

# --- Final info ---
IP=$(curl -s ifconfig.me || echo "localhost")
echo -e "${GREEN}=========================================================${NC}"
echo -e "Guacamole is now running behind Nginx."
echo -e "URL:  http://${SERVER_NAME}/"
echo -e "      http://${IP}/ (if DNS not set)"
echo -e "Login: ${GREEN}guacadmin/guacadmin${NC}"
echo -e "${RED}*** Change the default password immediately! ***${NC}"
echo -e "${GREEN}=========================================================${NC}"
