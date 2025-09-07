#!/bin/bash
set -euo pipefail

# Colors
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

GUACVERSION="1.5.5"
MYSQL_ROOT_PWD="password"
GUAC_USER="guacamole_user"
GUAC_PWD="password"
GUAC_DB="guacamole_db"
TOMCAT_VER=9.0.109

# Root check
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

echo -e "${BLUE}>>> Updating apt & installing base packages...${NC}"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -yq \
    xfce4 xfce4-goodies tightvncserver ufw curl wget zsh firefox \
    build-essential libjpeg-turbo8-dev libpng-dev libossp-uuid-dev \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
    freerdp2-dev libpango1.0-dev libssh2-1-dev libtelnet-dev \
    libvncserver-dev libpulse-dev libssl-dev libvorbis-dev libwebp-dev \
    libwebsockets-dev freerdp2-x11 libtool-bin ghostscript dpkg-dev crudini \
    mariadb-server mariadb-client

# ----------- Java ----------- #
if ! command -v java >/dev/null 2>&1; then
  echo -e "${BLUE}>>> Installing OpenJDK 17...${NC}"
  apt-get install -y openjdk-17-jre-headless
fi
JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
echo -e "${GREEN}JAVA_HOME detected as ${JAVA_HOME}${NC}"

# ----------- Firewall ----------- #
echo -e "${BLUE}>>> Configuring UFW...${NC}"
ufw --force enable
ufw allow ssh
ufw allow 8080/tcp
ufw reload

# ----------- VNC Server ----------- #
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

# ----------- Tomcat 9 ----------- #
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

# ----------- Guacamole ----------- #
cd /root
if [ ! -d guacamole-server-${GUACVERSION} ]; then
  echo -e "${BLUE}>>> Downloading Guacamole ${GUACVERSION}...${NC}"
  SERVER="https://downloads.apache.org/guacamole/${GUACVERSION}"
  wget -q ${SERVER}/source/guacamole-server-${GUACVERSION}.tar.gz
  tar -xzf guacamole-server-${GUACVERSION}.tar.gz
  wget -q ${SERVER}/binary/guacamole-${GUACVERSION}.war -O /etc/guacamole.war
  wget -q ${SERVER}/binary/guacamole-auth-jdbc-${GUACVERSION}.tar.gz
  tar -xzf guacamole-auth-jdbc-${GUACVERSION}.tar.gz
fi

# Build guacd if not installed
if ! command -v guacd >/dev/null 2>&1; then
  echo -e "${BLUE}>>> Building guacd...${NC}"
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

# MySQL setup
echo -e "${BLUE}>>> Setting up MySQL database...${NC}"
mysql -u root -p${MYSQL_ROOT_PWD} -e "DROP DATABASE IF EXISTS ${GUAC_DB}; CREATE DATABASE ${GUAC_DB};"
mysql -u root -p${MYSQL_ROOT_PWD} -e "DROP USER IF EXISTS '${GUAC_USER}'@'localhost'; CREATE USER '${GUAC_USER}'@'localhost' IDENTIFIED BY '${GUAC_PWD}'; GRANT SELECT,INSERT,UPDATE,DELETE ON ${GUAC_DB}.* TO '${GUAC_USER}'@'localhost'; FLUSH PRIVILEGES;"
cat guacamole-auth-jdbc-${GUACVERSION}/mysql/schema/*.sql | mysql -u root -p${MYSQL_ROOT_PWD} ${GUAC_DB}

cat > /etc/guacamole/guacamole.properties <<EOF
mysql-hostname: localhost
mysql-port: 3306
mysql-database: ${GUAC_DB}
mysql-username: ${GUAC_USER}
mysql-password: ${GUAC_PWD}
EOF

systemctl restart tomcat9

# ----------- Chrome ----------- #
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

# ----------- Tampermonkey ----------- #
EXT_ID="dhdgffkkebhmkfjojejmpbldmpobfkfo"
EXT_DIR="/opt/google/chrome/extensions"
if [ ! -f "$EXT_DIR/$EXT_ID.json" ]; then
  echo -e "${BLUE}>>> Registering Tampermonkey...${NC}"
  mkdir -p "$EXT_DIR"
  cat > "$EXT_DIR/$EXT_ID.json" <<EOF
{
  "external_update_url": "https://clients2.google.com/service/update2/crx"
}
EOF
fi

# ----------- Final info ----------- #
IP=$(curl -s ifconfig.me || echo "localhost")
echo -e "${GREEN}=========================================================${NC}"
echo -e "Guacamole URL: ${GREEN}http://${IP}:8080/guacamole${NC}"
echo -e "Login: ${GREEN}guacadmin/guacadmin${NC}"
echo -e "${RED}*** Change the password immediately! ***${NC}"
echo -e "${GREEN}=========================================================${NC}"
