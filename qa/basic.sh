#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test -f /etc/peaky-instance
exec > >(tee /tmp/basic-evidence.log) 2>&1
printf '\n=== BASIC: files and permissions ===\n'
install -d -m 0755 /home/student/peaky-lab
chown student:student /home/student/peaky-lab
runuser -u student -- bash -c 'cd ~/peaky-lab; mkdir -p "drafts/with spaces" archive; printf "document-001\n" > drafts/note.txt; cp drafts/note.txt archive/copy.txt; mv drafts/note.txt archive/note.txt; cmp archive/copy.txt archive/note.txt; test ! -e drafts/note.txt; ln -s archive/note.txt current; cat current'
groupadd list-editors
useradd -m -s /bin/bash list-worker
useradd -m -s /bin/bash list-viewer
usermod -aG list-editors list-worker
install -d -m 2770 -o root -g list-editors /srv/list-work
runuser -u list-worker -- sh -c 'printf "protected-document\n" > /srv/list-work/note.txt'
test "$(stat -c %G /srv/list-work/note.txt)" = list-editors
if runuser -u list-viewer -- cat /srv/list-work/note.txt; then echo 'unexpected outsider read'; exit 1; fi
chmod 0640 /srv/list-work/note.txt
setfacl -m u:list-viewer:rx /srv/list-work
setfacl -m u:list-viewer:r /srv/list-work/note.txt
runuser -u list-viewer -- cat /srv/list-work/note.txt
if runuser -u list-viewer -- sh -c 'printf forbidden >> /srv/list-work/note.txt'; then exit 1; fi
getfacl /srv/list-work/note.txt
printf '\n=== BASIC: service and actual document ===\n'
install -d -m 0750 -o root -g www-data /srv/list-portal
install -m 0640 -o root -g www-data /tmp/index.txt /srv/list-portal/index.txt
install -m 0644 /tmp/list-portal.conf /etc/nginx/conf.d/list-portal.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx
for i in $(seq 1 20); do ss -ltn | grep -q ':8080' && break; sleep 1; done
curl -fsS http://127.0.0.1:8080/index.txt | cmp - /srv/list-portal/index.txt
cp /etc/nginx/conf.d/list-portal.conf /tmp/portal-good.conf
printf '\ninvalid_directive;\n' >> /etc/nginx/conf.d/list-portal.conf
if nginx -t; then exit 1; fi
curl -fsS http://127.0.0.1:8080/index.txt | cmp - /srv/list-portal/index.txt
cp /tmp/portal-good.conf /etc/nginx/conf.d/list-portal.conf
nginx -t
systemctl reload nginx
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/missing.txt | grep -x 404
ss -ltn | grep ':8080'
systemctl is-enabled nginx
journalctl -u nginx -n 8 --no-pager
printf '\n=== BASIC: local DNS and port distinction ===\n'
printf '\n192.168.77.11 portal.lab.example\n' >> /etc/hosts
getent ahostsv4 portal.lab.example
ip route get 192.168.77.12
curl -fsS http://portal.lab.example:8080/index.txt | cmp - /srv/list-portal/index.txt
if curl -fsS --max-time 2 http://portal.lab.example:8081/index.txt; then exit 1; fi
printf '\n=== BASIC: complete restore and bad-copy refusal ===\n'
install -d -m 0700 /var/backups/peaky
tar --acls --xattrs -C /srv -czf /var/backups/peaky/work.tar.gz list-work
cd /var/backups/peaky
sha256sum work.tar.gz > SHA256SUMS
sha256sum -c SHA256SUMS
cp work.tar.gz corrupt.tar.gz
truncate -s 16 corrupt.tar.gz
if tar -tzf corrupt.tar.gz; then exit 1; fi
install -d -m 0700 /srv/list-restore
tar --acls --xattrs -C /srv/list-restore -xzf work.tar.gz
cmp /srv/list-work/note.txt /srv/list-restore/list-work/note.txt
getfacl /srv/list-restore/list-work/note.txt
test "$(stat -c '%a %U %G' /srv/list-work/note.txt)" = "$(stat -c '%a %U %G' /srv/list-restore/list-work/note.txt)"
printf '\n=== BASIC: timers and honest exit code ===\n'
install -m 0755 /tmp/list-check.sh /usr/local/bin/list-check
install -m 0644 /tmp/list-check.service /etc/systemd/system/list-check.service
install -m 0644 /tmp/list-check.timer /etc/systemd/system/list-check.timer
systemctl daemon-reload
systemctl start list-check.service
systemctl enable --now list-check.timer
systemctl list-timers list-check.timer --no-pager
chmod 0600 /srv/list-portal/index.txt
if systemctl start list-check.service; then echo 'false success'; exit 1; fi
journalctl -u list-check -n 12 --no-pager
chmod 0640 /srv/list-portal/index.txt
systemctl reset-failed list-check.service
systemctl start list-check.service
printf '\nBASIC PASS before reboot\n'
