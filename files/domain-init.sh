#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test "$(hostname)" = dc1
test -f /etc/peaky-instance
if test -f /etc/peaky-domain-prepared; then echo 'Own domain already exists'; exit 0; fi
test ! -f /var/lib/samba/private/sam.ldb || { echo 'Existing domain: inspect first'; exit 1; }
systemctl disable --now smbd nmbd winbind || true
mv /etc/samba/smb.conf /etc/samba/smb.conf.before-peaky
adminpass="A$(openssl rand -hex 16)!a"
install -m 0600 /dev/null /root/peaky-domain-admin.auth
printf 'username = Administrator\npassword = %s\ndomain = LAB\n' "$adminpass" > /root/peaky-domain-admin.auth
samba-tool domain provision --realm=LAB.EXAMPLE --domain=LAB --server-role=dc --dns-backend=SAMBA_INTERNAL --use-rfc2307 --host-name=dc1 --host-ip=192.168.77.13 --adminpass="$adminpass" --option='interfaces=lo lan0' --option='bind interfaces only=yes'
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
systemctl unmask samba-ad-dc
systemctl enable --now samba-ad-dc
touch /etc/peaky-domain-prepared
echo 'Own Samba AD initialized; private credentials remain on dc1'
