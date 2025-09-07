#!/bin/bash
set -euo pipefail

# ============================================================
# Guacamole Install Script (Ubuntu 24.04+, ARM/AMD)
# With tmux dashboard, guacd IPv4 bind, and TightVNC (root)
# ============================================================

GUACVERSION="1.5.5"
GUAC_USER="guacamole_user"
GUAC_DB="guacamole_db"
TOMCAT_VER=9.0.109
CRED_FILE="/root/guacamole-credentials.txt"

# Temporary bootstrap passwords (rotated at end)
MYSQL_ROOT_PWD="root"
GUAC_PWD="guac"

YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log(){ echo -e "$@"; }

# ============================================================
# Monitoring setup (tmux split screen)
# ============================================================
if [ -z "${INSIDE_TMUX:-}" ]; then
  apt-get update -y
  apt-get install -y tmux htop iftop
  export INSIDE_TMUX=1

  SCRIPT_PATH="$(realpath "$0")"
  SCRIPT_CMD="INSIDE_TMUX=1 bash \"$SCRIPT_PATH\" $*"

  tmux new-session -d -s guac-install \
    "echo '>>> Running: $SCRIPT_CMD'; sleep 3; $SCRIPT_CMD"
  tmux split-window -h "htop"
  tmux split-window -v -t 0 "iftop -i \$(ip -o -4 route show to default | awk '{print \$5}' | head -n1)"
  tmux split-window -v -t 1 "tail -f /var/log/syslog"
  tmux select-layout tiled
  tmux attach -t guac-install
  exit 0
fi

# ============================================================
# Detect SERVER_NAME (IPv4 reverse DNS default)
# ============================================================
SERVER_NAME=${SERVER_NAME:-}
if [ -z "$SERVER_NAME" ]; then
  PUBIP=$(curl -4 -s ifconfig.me || echo "")
  if [ -n "$PUBIP" ]; then
    apt-get install -y -qq dnsutils >/dev/null 2>&1 || true
    REVNAME=$(dig +short -x "$PUBIP" @8.8.8.8 | sed 's/\.$//' || true)
    DEFAULT_NAME=${REVNAME:-$PUBIP}
  else
    DEFAULT_NAME="localhost"
  fi
  if [ -t 0 ]; then
    read -p "Enter server name for Nginx/Let's Encrypt [${DEFAULT_NAME}]: " SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$DEFAULT_NAME}
  else
    SERVER_NAME=$DEFAULT_NAME
    log "${YELLOW}No SERVER_NAME provided, using default: ${SERVER_NAME}${NC}"
  fi
fi

# ============================================================
# Base packages
# ============================================================
log "${BLUE}>>> Installing base packages...${NC}"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -yq \
  xfce4 xfce4-goodies tightvncserver ufw curl wget zsh dnsutils \
  build-essential libjpeg-turbo8-dev libpng-dev libossp-uuid-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
  freerdp2-dev libpango1.0-dev libssh2-1-dev libtelnet-dev \
  libvncserver-dev libpulse-dev libssl-dev libvorbis-dev libwebp-dev \
  libwebsockets-dev freerdp2-x11 libtool-bin ghostscript dpkg-dev crudini \
  mariadb-server mariadb-client nginx certbot python3-certbot-nginx openssl

# ============================================================
# Java
# ============================================================
if ! command -v java >/dev/null 2>&1; then
  apt-get install -y openjdk-17-jre-headless
fi
JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(which java)")")")
log "${GREEN}JAVA_HOME=${JAVA_HOME}${NC}"

# ============================================================
# Firewall basics (web only – VNC stays localhost)
# ============================================================
ufw --force enable
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw reload

# ============================================================
# Tomcat 9
# ============================================================
if [ ! -d /opt/apache-tomcat-${TOMCAT_VER} ]; then
  log "${BLUE}>>> Installing Tomcat ${TOMCAT_VER}...${NC}"
  cd /opt
  wget -q "https://downloads.apache.org/tomcat/tomcat-9/v${TOMCAT_VER}/bin/apache-tomcat-${TOMCAT_VER}.tar.gz"
  tar -xzf "apache-tomcat-${TOMCAT_VER}.tar.gz"
  ln -sfn "apache-tomcat-${TOMCAT_VER}" tomcat9
  id -u tomcat >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin tomcat
  chown -R tomcat:tomcat "/opt/apache-tomcat-${TOMCAT_VER}"
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

# ============================================================
# Guacamole (server + webapp + JDBC)
# ============================================================
cd /root
SERVER_URL="https://downloads.apache.org/guacamole/${GUACVERSION}"
wget -q "${SERVER_URL}/source/guacamole-server-${GUACVERSION}.tar.gz" -O "guacamole-server-${GUACVERSION}.tar.gz"
tar -xzf "guacamole-server-${GUACVERSION}.tar.gz"
wget -q "${SERVER_URL}/binary/guacamole-${GUACVERSION}.war" -O /etc/guacamole.war
wget -q "${SERVER_URL}/binary/guacamole-auth-jdbc-${GUACVERSION}.tar.gz" -O "guacamole-auth-jdbc-${GUACVERSION}.tar.gz"
tar -xzf "guacamole-auth-jdbc-${GUACVERSION}.tar.gz"

if ! command -v guacd >/dev/null 2>&1; then
  cd "guacamole-server-${GUACVERSION}"
  ./configure --with-systemd-dir=/etc/systemd/system
  make -j"$(nproc)"
  make install
  ldconfig
  cd ..
fi

# ---------------- guacd: systemd unit (if not present) ----------------
if [ ! -f /etc/systemd/system/guacd.service ]; then
  cat > /etc/systemd/system/guacd.service <<'EOF'
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

# ---------------- Configuring guacd (force IPv4) ----------------
# Bind to 127.0.0.1:4822 to avoid ::1-only bind causing "Connection refused"
log "${BLUE}Configuring guacd (IPv4 bind)...${NC}"
mkdir -p /etc/guacamole
cat > /etc/guacamole/guacd.conf <<'EOF'
[server]
bind_host = 127.0.0.1
bind_port = 4822
EOF
systemctl daemon-reexec
systemctl enable --now guacd

# Webapp + JDBC extension
mkdir -p /etc/guacamole/extensions /etc/guacamole/lib
cp /etc/guacamole.war /opt/tomcat9/webapps/guacamole.war
cp "guacamole-auth-jdbc-${GUACVERSION}/mysql/guacamole-auth-jdbc-mysql-${GUACVERSION}.jar" /etc/guacamole/extensions/

# ============================================================
# JDBC Connector (prefer MariaDB, fallback to MySQL Connector/J)
# ============================================================
log "${BLUE}>>> Installing JDBC driver for MySQL/MariaDB...${NC}"
if apt-cache show libmariadb-java 2>/dev/null | grep -q '^Package:'; then
  apt-get install -y libmariadb-java
  ln -sf /usr/share/java/mariadb-java-client.jar /etc/guacamole/lib/mysql-connector-java.jar
  log "${GREEN}MariaDB JDBC connector installed.${NC}"
else
  cd /tmp
  wget -q https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-j-8.3.0.tar.gz
  tar -xzf mysql-connector-j-8.3.0.tar.gz
  cp mysql-connector-j-8.3.0/mysql-connector-j-8.3.0.jar /etc/guacamole/lib/mysql-connector-java.jar
  log "${GREEN}MySQL Connector/J installed.${NC}"
fi

# ============================================================
# MySQL / MariaDB
# ============================================================
# Set root password (switch from unix_socket to password)
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PWD}';
EOF

# DB + user
if ! mysql -u root -p"${MYSQL_ROOT_PWD}" -e "USE ${GUAC_DB}" 2>/dev/null; then
  mysql -u root -p"${MYSQL_ROOT_PWD}" -e "CREATE DATABASE ${GUAC_DB};"
fi

USER_EXISTS=$(mysql -u root -p"${MYSQL_ROOT_PWD}" -Nse "SELECT COUNT(*) FROM mysql.user WHERE user='${GUAC_USER}'")
if [ "$USER_EXISTS" -eq 0 ]; then
  mysql -u root -p"${MYSQL_ROOT_PWD}" -e "CREATE USER '${GUAC_USER}'@'localhost' IDENTIFIED BY '${GUAC_PWD}';"
  mysql -u root -p"${MYSQL_ROOT_PWD}" -e "GRANT SELECT,INSERT,UPDATE,DELETE ON ${GUAC_DB}.* TO '${GUAC_USER}'@'localhost'; FLUSH PRIVILEGES;"
fi

# Schema load (first time)
if ! mysql -u root -p"${MYSQL_ROOT_PWD}" -D "${GUAC_DB}" -e "SHOW TABLES;" | grep -q '^guacamole_user$'; then
  cat "guacamole-auth-jdbc-${GUACVERSION}/mysql/schema/"*.sql | mysql -u root -p"${MYSQL_ROOT_PWD}" "${GUAC_DB}"
fi

# Explicitly set DB + guacd params & disable DB SSL (common cause of failures)
cat > /etc/guacamole/guacamole.properties <<EOF
guacd-hostname: 127.0.0.1
guacd-port: 4822

mysql-hostname: localhost
mysql-port: 3306
mysql-database: ${GUAC_DB}
mysql-username: ${GUAC_USER}
mysql-password: ${GUAC_PWD}
mysql-ssl-mode: disabled
EOF

systemctl restart tomcat9

# ============================================================
# Nginx reverse proxy (root path "/")
# ============================================================
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

# Let's Encrypt (fallback to self-signed)
if certbot --nginx -d "${SERVER_NAME}" --non-interactive --agree-tos -m "admin@${SERVER_NAME}" --redirect; then
  log "${GREEN}Let's Encrypt OK.${NC}"
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

# ============================================================
# TightVNC (root) + XFCE via systemd  <-- NEW/UPDATED
# ============================================================
log "${BLUE}>>> Configuring TightVNC for root (localhost only)...${NC}"

# Generate a random 8-char VNC password (TightVNC allows up to 8)
VNC_PWD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8 || true)"
mkdir -p /root/.vnc
printf "%s" "${VNC_PWD}" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

# xstartup launching XFCE
cat > /root/.vnc/xstartup <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
xrdb $HOME/.Xresources
startxfce4 &
EOF
chmod +x /root/.vnc/xstartup

# systemd service for display :1 (port 5901), localhost only
cat > /etc/systemd/system/vncserver@.service <<'EOF'
[Unit]
Description=TightVNC server on display %i
After=network.target

[Service]
Type=forking
User=root
Group=root
WorkingDirectory=/root
PIDFile=/root/.vnc/%H:%i.pid
# -localhost keeps it bound to 127.0.0.1 (not exposed)
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1280x800 -localhost :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vncserver@1.service

# ============================================================
# Create default Guacamole connections (VNC & SSH to localhost)
# ============================================================
mysql -u root -p"${MYSQL_ROOT_PWD}" "${GUAC_DB}" <<'EOF'
-- VNC
INSERT INTO guacamole_connection (connection_name, protocol)
SELECT 'Default VNC','vnc' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM guacamole_connection WHERE connection_name='Default VNC');

SET @CID := (SELECT connection_id FROM guacamole_connection WHERE connection_name='Default VNC');
INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
VALUES (@CID,'hostname','localhost'),(@CID,'port','5901');

-- Give guacadmin full perms on it
INSERT IGNORE INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, @CID, p.permission
FROM guacamole_entity e
JOIN (SELECT 'READ' AS permission UNION ALL SELECT 'UPDATE' UNION ALL SELECT 'DELETE' UNION ALL SELECT 'ADMINISTER') p
WHERE e.name='guacadmin' AND e.type='USER';

-- SSH
INSERT INTO guacamole_connection (connection_name, protocol)
SELECT 'Default SSH','ssh' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM guacamole_connection WHERE connection_name='Default SSH');

SET @SID := (SELECT connection_id FROM guacamole_connection WHERE connection_name='Default SSH');
INSERT IGNORE INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
VALUES (@SID,'hostname','localhost'),(@SID,'port','22');

INSERT IGNORE INTO guacamole_connection_permission (entity_id, connection_id, permission)
SELECT e.entity_id, @SID, p.permission
FROM guacamole_entity e
JOIN (SELECT 'READ' AS permission UNION ALL SELECT 'UPDATE' UNION ALL SELECT 'DELETE' UNION ALL SELECT 'ADMINISTER') p
WHERE e.name='guacadmin' AND e.type='USER';
EOF

systemctl restart tomcat9

# ============================================================
# Tailscale (optional, unchanged)
# ============================================================
log "${BLUE}>>> Installing Tailscale...${NC}"
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
if [ -t 0 ]; then
  read -p "Enter Tailscale auth key (leave blank for interactive login): " TSKEY || true
else
  TSKEY=""
fi
if [ -n "${TSKEY:-}" ]; then
  tailscale up --authkey="${TSKEY}" --ssh
else
  tailscale up --ssh
fi

# ============================================================
# Rotate MySQL passwords at the end (safe; updates guacamole.properties)
# ============================================================
FINAL_MYSQL_ROOT_PWD=$(openssl rand -base64 20)
FINAL_GUAC_PWD=$(openssl rand -base64 20)

mysql -u root -p"${MYSQL_ROOT_PWD}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${FINAL_MYSQL_ROOT_PWD}';"
mysql -u root -p"${FINAL_MYSQL_ROOT_PWD}" -e "ALTER USER '${GUAC_USER}'@'localhost' IDENTIFIED BY '${FINAL_GUAC_PWD}'; FLUSH PRIVILEGES;"

crudini --set /etc/guacamole/guacamole.properties '' mysql-password "${FINAL_GUAC_PWD}"
systemctl restart tomcat9

# ============================================================
# Save credentials
# ============================================================
cat > "${CRED_FILE}" <<EOF
Guacamole URL:
  https://${SERVER_NAME}/

Default Guacamole admin:
  User: guacadmin
  Pass: guacadmin
  (Change immediately in Settings → Preferences)

MySQL root password:
  ${FINAL_MYSQL_ROOT_PWD}

MySQL Guacamole user (${GUAC_USER}) password:
  ${FINAL_GUAC_PWD}

TightVNC (root) password (for :1 / 5901):
  ${VNC_PWD}

Notes:
  - VNC listens on localhost only (-localhost). Guacamole uses it via 'Default VNC'.
  - guacd binds to 127.0.0.1:4822 (IPv4) to avoid ::1-only issues.
EOF
chmod 600 "${CRED_FILE}"

IP4=$(curl -4 -s ifconfig.me || echo "localhost")
echo -e "${GREEN}=========================================================${NC}"
echo -e "Guacamole: https://${SERVER_NAME}/   (fallback https://${IP4}/ )"
echo -e "Login: guacadmin / guacadmin  ${RED}(change immediately)${NC}"
echo -e "MySQL root:   ${FINAL_MYSQL_ROOT_PWD}"
echo -e "MySQL ${GUAC_USER}: ${FINAL_GUAC_PWD}"
echo -e "VNC (root) password: ${VNC_PWD}   (localhost:5901)"
echo -e "Saved in: ${CRED_FILE}"
echo -e "${GREEN}=========================================================${NC}"
