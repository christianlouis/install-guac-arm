#!/bin/bash
set -euo pipefail

# Colors
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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
systemctl enable vncserver@1.service || true
systemctl daemon-reload
systemctl start vncserver@1 || true

# ----------- Tomcat 9 ----------- #
TOMCAT_VER=9.0.109
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
echo -e "${BLUE}>>> Installing Guacamole...${NC}"
cd /root
curl -sSL https://raw.githubusercontent.com/MysticRyuujin/guac-install/master/guac-install.sh -o guac-install.sh
chmod +x guac-install.sh

# Patch installer to use /opt/tomcat9
sed -i 's#/var/lib/${TOMCAT}/webapps/#/opt/tomcat9/webapps/#' guac-install.sh
sed -i 's/service ${TOMCAT} restart/systemctl restart tomcat9/' guac-install.sh
sed -i 's/systemctl enable ${TOMCAT}/systemctl enable tomcat9/' guac-install.sh
sed -i 's/echo -e "${RED}Failed. Can.t find Tomcat package.*exit 1/echo "Using external Tomcat9"/' guac-install.sh

# Run installer (idempotent: drops db if exists, recreates)
./guac-install.sh --mysqlpwd password --guacpwd password --nomfa --installmysql || true
rm guac-install.sh

# ----------- guacd sanity ----------- #
systemctl enable guacd || true
systemctl restart guacd || true
pgrep -x guacd >/dev/null || (echo -e "${RED}guacd failed to start, try running manually${NC}")

# ----------- Final info ----------- #
IP=$(curl -s ifconfig.me || echo "localhost")
echo -e "${GREEN}=========================================================${NC}"
echo -e "Guacamole URL: ${GREEN}http://${IP}:8080/guacamole${NC}"
echo -e "Login: ${GREEN}guacadmin/guacadmin${NC}"
echo -e "${RED}*** Change the password immediately! ***${NC}"
echo -e "${GREEN}=========================================================${NC}"
