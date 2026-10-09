#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test -f /etc/peaky-instance
if test -f /etc/peaky-prepared; then echo 'Already prepared; document preserved'; exit 0; fi
test ! -e /srv/list-portal/index.txt || { echo 'Existing document: inspect instead of overwriting'; exit 1; }
base=/home/student/peaky-setup
install -d -m 0750 -o root -g www-data /srv/list-portal
install -m 0640 -o root -g www-data "$base/index.txt" /srv/list-portal/index.txt
install -m 0644 "$base/list-portal.conf" /etc/nginx/conf.d/list-portal.conf
install -m 0755 "$base/list-check.sh" /usr/local/bin/list-check
for name in list-check.service list-check.timer; do install -m 0644 "$base/$name" "/etc/systemd/system/$name"; done
nginx -t
systemctl enable --now nginx
systemctl reload nginx
systemctl daemon-reload
systemctl enable --now list-check.timer
touch /etc/peaky-prepared
echo 'Own portal prepared; baseline document installed'
