#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test -f /etc/peaky-instance
exec > >(tee /tmp/advanced-evidence.log) 2>&1
printf '\n=== ADVANCED: real systemd ordering and requirement ===\n'
cat > /etc/systemd/system/list-source.service <<'EOF'
[Unit]
Description=Own source readiness marker
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/test -f /srv/list-portal/index.txt
EOF
cat > /etc/systemd/system/list-dependent.service <<'EOF'
[Unit]
Description=Dependent document check
Requires=list-source.service
After=list-source.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/list-check
EOF
systemctl daemon-reload
systemctl start list-dependent.service
systemctl stop list-source.service
mv /srv/list-portal/index.txt /srv/list-portal/index.saved
if systemctl start list-dependent.service; then exit 1; fi
mv /srv/list-portal/index.saved /srv/list-portal/index.txt
systemctl reset-failed list-source.service list-dependent.service
systemctl start list-dependent.service
systemctl show list-dependent.service -p After -p Requires -p Result
printf '\n=== ADVANCED: real storage inside an owned image ===\n'
truncate -s 96M /var/lib/peaky-store.img
loop=$(losetup --find --show /var/lib/peaky-store.img)
trap 'umount /srv/list-store 2>/dev/null || true; vgchange -an peaky-vg 2>/dev/null || true; losetup -d "$loop" 2>/dev/null || true' EXIT
pvcreate "$loop"
vgcreate peaky-vg "$loop"
lvcreate -L 24M -n documents peaky-vg
mkfs.ext4 -m 0 /dev/peaky-vg/documents
mkdir /srv/list-store
mount /dev/peaky-vg/documents /srv/list-store
printf 'old-storage-record\n' > /srv/list-store/old.txt
sha256sum /srv/list-store/old.txt
lvextend -L +24M /dev/peaky-vg/documents
resize2fs /dev/peaky-vg/documents
grep -x old-storage-record /srv/list-store/old.txt
df -h /srv/list-store
mount -o remount,ro /srv/list-store
if sh -c 'printf new > /srv/list-store/new.txt'; then exit 1; fi
findmnt -no SOURCE,FSTYPE,OPTIONS /srv/list-store
mount -o remount,rw /srv/list-store
printf new > /srv/list-store/new.txt
printf '\n=== ADVANCED: exact sudo command and denied broader scope ===\n'
useradd -m -s /bin/bash list-operator
printf 'list-operator ALL=(root) NOPASSWD: /usr/bin/systemctl --no-pager status nginx\n' > /etc/sudoers.d/list-operator
chmod 0440 /etc/sudoers.d/list-operator
visudo -cf /etc/sudoers.d/list-operator
runuser -u list-operator -- sudo -n /usr/bin/systemctl --no-pager status nginx
if runuser -u list-operator -- sudo -n /usr/bin/systemctl restart nginx; then exit 1; fi
printf '\n=== ADVANCED: journal and complete-document evidence ===\n'
logger -t list-incident 'planned access test, case=ADV-001'
journalctl -t list-incident -n 1 --no-pager | grep ADV-001
curl -fsS http://127.0.0.1:8080/index.txt | cmp - /srv/list-portal/index.txt
printf '\nADVANCED LOCAL PASS\n'
