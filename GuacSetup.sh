#!/bin/bash
#
# This script sets up Apache Guacamole v1.0.0 on Ubuntu 18.04
# Default authentication is MySQL database - you must provide this
# Nginx is setup as reverse proxy and forces HTTPS so you must provide valid certificate
#
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# AWS Ubuntu 18.04 image doesn't play nice with ipv6
echo "net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p

GUAC_VERSION=1.0.0
GUAC_SERVER=guacamole-server-${GUAC_VERSION}
GUAC_CLIENT=guacamole-client-${GUAC_VERSION}
GUAC_SERVER_DOWNLOAD=http://archive.apache.org/dist/guacamole/1.0.0/source/${GUAC_SERVER}.tar.gz
GUAC_CLIENT_DOWNLOAD=http://archive.apache.org/dist/guacamole/1.0.0/source/${GUAC_CLIENT}.tar.gz

# Update and upgrade using apt update and apt upgrade
apt update
apt upgrade -y

# Install dependencies
apt install -y dpkg autoconf libtool build-essential wget maven nginx tomcat9 fail2ban openjdk-8-jdk libjpeg-turbo8-dev \
	libcairo2-dev libpng-dev libossp-uuid-dev libssl-dev libwebp-dev libmysql-java

# Install VNC dependencies
apt install -y libvncserver-dev libpulse-dev

# Install RDP dependencies
apt install -y libfreerdp-dev

# Install SSH dependencies
apt install -y libpango1.0-dev libssh2-1-dev

# Install Telnet dependencies
apt install -y libtelnet-dev

# Add environment variable
export JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
export PATH=$PATH:$JAVA_HOME/bin

# Add GUACAMOLE_HOME variable to tomcat9
echo "GUACAMOLE_HOME=/etc/guacamole" >> /etc/default/tomcat9

# Setup server for guacamole-server
mkdir /etc/guacamole
mkdir -p /etc/guacamole/{lib,extensions}

# Download, extract, build guacamole-server
wget ${GUAC_SERVER_DOWNLOAD}
tar -xzf ${GUAC_SERVER}.tar.gz
rm -f ${GUAC_SERVER}.tar.gz
mv ${GUAC_SERVER} guacserver
sleep 1 && cd guacserver
autoreconf -fi
./configure --with-init-dir=/etc/init.d
make
sleep 1 && make install
sleep 1 && ldconfig
cd ..

# Copy MySQL Connector Java to /etc/guacamole/lib
cp /usr/share/java/mysql-connector-java-*.jar /etc/guacamole/lib/

# Get build-folder
BUILD_FOLDER=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
mkdir /usr/lib/${BUILD_FOLDER}/freerdp
ln -fs /usr/local/lib/freerdp/guac*.so /usr/lib/${BUILD_FOLDER}/freerdp
ln -fs /etc/guacamole /usr/share/tomcat9/.guacamole

# Download, extract, build guacamole-client
wget ${GUAC_CLIENT_DOWNLOAD}
tar -xzf ${GUAC_CLIENT}.tar.gz
rm -f ${GUAC_CLIENT}.tar.gz
mv ${GUAC_CLIENT} guacclient
sleep 1 && cd guacclient
mvn package
cp guacamole/target/${GUAC_CLIENT}.war /etc/guacamole/app.war

# Copy the applicable authentication extension(s) to /etc/guacamole/extensions/
# MySQL auth
cp extensions/guacamole-auth-jdbc/modules/guacamole-auth-jdbc/mysql/target/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar /etc/guacamole/extensions/
# OpenID auth
#cp extensions/guacamole-auth-jdbc/modules/guacamole-auth-openid/target/guacamole-auth-openid-${GUAC_VERSION}.jar /etc/guacamole/extensions/
# TOTP aka MFA
#cp extensions/guacamole-auth-jdbc/modules/guacamole-auth-totp/target/guacamole-auth-totp-${GUAC_VERSION}.jar /etc/guacamole/extensions/

# Create a guacamole.properties file for the authentication extension(s)
echo "#MySQL Properties
#Property info: https://guacamole.apache.org/doc/1.0.0/gug/jdbc-auth.html
mysql-hostname: MYSQL-HOSTNAME-HERE
mysql-port: 3306
mysql-database: MYSQL-DATABASE-NAME
mysql-username: MYSQL-USERNAME-HERE
mysql-password: MYSQL-PASSWORD-HERE

#OpenID Properties
#Uncomment the following lines to enable OpenID authentication alongside MySQL authentication
#Property info: https://guacamole.apache.org/doc/1.0.0/gug/openid-auth.html
#openid-authorization-endpoint: ENDPOINT-URI
#openid-jwks-endpoint: JWKS-ENDPOINT-URI
#openid-issuer: ISSUER-PROP
#openid-client-id: CLIENT-ID
#openid-redirect-uri: REDIRECT-URI
#openid-username-claim-type: NAME-CLAIM-TYPE
#openid-scope: OPENID-SCOPE
#openid-allowed-clock-skew: CLOCK-SKEW
#openid-max-token-validity: TOKEN-VALIDITY
#openid-max-nonce-validity: NONCE-VALIDITY

#TOTP Properties
#Uncomment the following lines to enable TOTP (2FA) authentication
#Property info: https://guacamole.apache.org/doc/1.0.0/gug/totp-auth.html
#totp-issuer: WEBSERVICE-NAME
#totp-digits: NUM-OF-DIGITS
#totp-period: TIME-IN-SECONDS
#totp-mode: HASH-ALGORITHM-SHA" > /etc/guacamole/guacamole.properties

# Delete the ROOT tomcat9 website so we may replace with Guacamole
rm -rf /var/lib/tomcat9/webapps/ROOT*
ln-fs /etc/guacamole/app.war /var/lib/tomcat9/webapps/ROOT.war

# Setup tomcat and nginx
cp /etc/tomcat9/server.xml /etc/tomcat9/server.xml.bak
sed -i 's|</Host>|<Valve className="org.apache.catalina.valves.RemoteIpValve" internalProxies="127.0.0.1" remoteIpHeader="x-forwarded-for" remoteIpProxiesHeader="x-forwarded-by" protocolHeader="x-forwarded-proto" />\n</Host>|g' /etc/tomcat9/server.xml
mv /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak
echo "server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name localhost;
        return 301 https://$host$request_uri;
}

server {
        listen 443 ssl http2;
        server_name localhost;
        root /var/lib/tomcat9/webapps/ROOT;
        client_max_body_size 10m;

        ssl_certificate bundle.pem;
        ssl_certificate_key server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5;
        location / {
                proxy_pass http://localhost:8080/;
                proxy_buffering off;
                proxy_http_version 1.1;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header Upgrade $http_upgrade;
                proxy_set_header Connection $http_connection;
                proxy_cookie_path / /;
                access_log off;
    }
}" > /etc/nginx/sites-available/default
echo "You must provide a valid SSL/TLS certificate and place it in /etc/nginx/bundle.pem and /etc/nginx/server.key"

# Setup fail2ban for gateway/guacamole
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local | tee -a $logfile || exit 1
sed -i ':a;N;$!ba;s/\[guacamole\]\n\nport/[guacamole]\nenabled = true\nport/g' /etc/fail2ban/jail.local
sed -i ':a;N;$!ba;s/\/var\/log\/tomcat\*\/catalina.out/\/var\/log\/syslog/g' /etc/fail2ban/jail.local
sed -i 's/failregex = /failregex = ^.*Authentication attempt from <HOST> for user "[^"]*" failed\.$\n#/g' /etc/fail2ban/filter.d/guacamole.conf
fail2ban-client reload

# Enable services for system startup
systemctl enable tomcat9
systemctl enable nginx
systemctl enable guacd

# Start services
systemctl start guacd
systemctl start tomcat9
systemctl start nginx
