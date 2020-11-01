#!/bin/bash

source /etc/wspecs/global.conf
source /etc/wspecs/functions.sh

# Open ports.
ufw_allow http
ufw_allow https

# Some Ubuntu images start off with Apache. Remove it since we
# will use nginx. Use autoremove to remove any Apache depenencies.
if [ -f /usr/sbin/apache2 ]; then
  echo Removing apache...
  hide_output apt-get -y purge apache2 apache2-*
  hide_output apt-get -y --purge autoremove
fi

# Install nginx and a PHP FastCGI daemon.
#
# Turn off nginx's default website.

echo "Installing Nginx (web server)..."

install_once nginx
install_once mysql-server

echo Updating PHP config
PHP_VERSION=7.4
add_config PHP_VERSION=$PHP_VERSION /etc/wspecs/global.conf
install_once php$PHP_VERSION-cli
install_once php$PHP_VERSION-fpm
install_once php$PHP_VERSION-mysql
install_once php$PHP_VERSION-curl
install_once php$PHP_VERSION-gd
install_once php$PHP_VERSION-mbstring
install_once php$PHP_VERSION-xml

cp php.ini /etc/php/$PHP_VERSION/fpm/php.ini
sudo systemctl restart php$PHP_VERSION-fpm

if [ -f "$HOME/.my.cnf" ]; then
  echo MySQL login is already configured
else
  echo "Setting up MYSQL login"
  NEW_PASSWORD=$(openssl rand -base64 36 | tr -d "=+/" | cut -c1-32)
  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$NEW_PASSWORD';"
  mysql -e "DELETE FROM mysql.user WHERE User=''"
  mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1')"
  mysql -e "DROP DATABASE IF EXISTS test"
  mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
  mysql -e "FLUSH PRIVILEGES"

  echo "Creating mysql config"
  cat > $HOME/.my.cnf <<EOL
[mysql]
user=root
password=$NEW_PASSWORD
EOL
  chmod 0600 $HOME/.my.cnf
fi

rm -f /etc/nginx/sites-enabled/default

# Copy in a nginx configuration file for common and best-practices
# SSL settings from @konklone. Replace STORAGE_ROOT so it can find
# the DH params.
rm -f /etc/nginx/nginx-ssl.conf # we used to put it here

sed "s#STORAGE_ROOT#$STORAGE_ROOT#" \
  nginx-ssl.conf > /etc/nginx/conf.d/ssl.conf
sed "s#STORAGE_ROOT#$STORAGE_ROOT#" \
  nginx-default.conf > /etc/nginx/conf.d/default.conf

edit_config /etc/nginx/nginx.conf -s \
  server_names_hash_bucket_size="128;" \
  ssl_protocols="TLSv1.2 TLSv1.3;"

# Set PHPs default charset to UTF-8, since we use it. See #367.
edit_config /etc/php/$PHP_VERSION/fpm/php.ini -c ';' \
        default_charset="UTF-8"

# Configure the path environment for php-fpm
edit_config /etc/php/$PHP_VERSION/fpm/pool.d/www.conf -c ';' \
  env[PATH]=/usr/local/bin:/usr/bin:/bin \

edit_config /etc/php/$PHP_VERSION/fpm/pool.d/www.conf -c ';' \
                pm=ondemand \
                pm.max_children=16 \
                pm.start_servers=4 \
                pm.min_spare_servers=1 \
                pm.max_spare_servers=6

# Create the iOS/OS X Mobile Configuration file which is exposed via the
# nginx configuration at /wspecsbox-mobileconfig.
mkdir -p /var/lib/wspecsbox
chmod a+rx /var/lib/wspecsbox
cat ios-profile.xml \
  | sed "s/PRIMARY_HOSTNAME/$PRIMARY_HOSTNAME/" \
  | sed "s/UUID1/$(cat /proc/sys/kernel/random/uuid)/" \
  | sed "s/UUID2/$(cat /proc/sys/kernel/random/uuid)/" \
  | sed "s/UUID3/$(cat /proc/sys/kernel/random/uuid)/" \
  | sed "s/UUID4/$(cat /proc/sys/kernel/random/uuid)/" \
   > /var/lib/wspecsbox/mobileconfig.xml
chmod a+r /var/lib/wspecsbox/mobileconfig.xml

# Create the Mozilla Auto-configuration file which is exposed via the
# nginx configuration at /.well-known/autoconfig/mail/config-v1.1.xml.
# The format of the file is documented at:
# https://wiki.mozilla.org/Thunderbird:Autoconfiguration:ConfigFileFormat
# and https://developer.mozilla.org/en-US/docs/Mozilla/Thunderbird/Autoconfiguration/FileFormat/HowTo.
cat mozilla-autoconfig.xml \
  | sed "s/PRIMARY_HOSTNAME/$PRIMARY_HOSTNAME/" \
   > /var/lib/wspecsbox/mozilla-autoconfig.xml
chmod a+r /var/lib/wspecsbox/mozilla-autoconfig.xml

# make a default homepage
if [ -d $STORAGE_ROOT/www/static ]; then mv $STORAGE_ROOT/www/static $STORAGE_ROOT/www/default; fi # migration #NODOC
mkdir -p $STORAGE_ROOT/www/default
if [ ! -f $STORAGE_ROOT/www/default/index.html ]; then
  cp index.html $STORAGE_ROOT/www/default/index.html
fi
chown -R $STORAGE_USER $STORAGE_ROOT/www

# Start services.
restart_service nginx
restart_service php$PHP_VERSION-fpm

# Register with Let's Encrypt, including agreeing to the Terms of Service.
# We'd let certbot ask the user interactively, but when this script is
# run in the recommended curl-pipe-to-bash method there is no TTY and
# certbot will fail if it tries to ask.
if [ ! -d $STORAGE_ROOT/ssl/lets_encrypt/accounts/acme-v02.api.letsencrypt.org/ ]; then
  certbot register --register-unsafely-without-email --agree-tos --config-dir $STORAGE_ROOT/ssl/lets_encrypt
fi

# Open ports.
ufw_allow http
ufw_allow https

