# Prepares the systemd container like a production host: a deploy user, the
# service unit, its env file, the installer and its sudoers rule.
set -euo pipefail
db_host="$1"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq curl sudo mariadb-client >/dev/null

useradd -m -s /bin/bash deploy
install -d -o deploy -g deploy -m 0755 /srv/deploy/incoming

# root reaches the database the way it does in production (there through the
# local socket, here over the test network).
printf '[client]\nhost=%s\nuser=root\npassword=test-root\n' "$db_host" > /root/.my.cnf
chmod 600 /root/.my.cnf
mariadb -e "CREATE TABLE shop.schema_migrations (version VARCHAR(20) PRIMARY KEY)"
mariadb -e "INSERT INTO shop.schema_migrations VALUES ('001'), ('002')"

install -d -m 0700 /etc/api
printf 'DB_DSN=app:secret@tcp(%s:3306)/shop?parseTime=true\nLISTEN_ADDR=127.0.0.1:8090\n' "$db_host" > /etc/api/api.env
chmod 600 /etc/api/api.env

# A stand-in for mariadb.service, which the real unit requires.
printf '[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' \
  > /etc/systemd/system/mariadb.service
printf '[Unit]\nAfter=mariadb.service\nRequires=mariadb.service\n[Service]\nUser=www-data\nExecStart=/opt/api/api\nEnvironmentFile=/etc/api/api.env\nRestart=always\nRestartSec=1\n[Install]\nWantedBy=multi-user.target\n' \
  > /etc/systemd/system/api.service
systemctl daemon-reload
systemctl enable --now mariadb >/dev/null 2>&1
systemctl enable api >/dev/null 2>&1

install -o root -g root -m 0755 /t/install-api.sh /usr/local/sbin/install-api
visudo -cf /t/example.sudoers >/dev/null
install -o root -g root -m 0440 /t/example.sudoers /etc/sudoers.d/deploy-api
echo "== Host ready"
