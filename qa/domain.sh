#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test -f /etc/peaky-instance
exec > >(tee /tmp/domain-evidence.log) 2>&1
printf '\n=== ADVANCED: actual Samba AD directory ===\n'
systemctl disable --now smbd nmbd winbind || true
mv /etc/samba/smb.conf /etc/samba/smb.conf.before-peaky
adminpass="A$(openssl rand -hex 16)!a"
samba-tool domain provision --realm=LAB.EXAMPLE --domain=LAB --server-role=dc --dns-backend=SAMBA_INTERNAL --use-rfc2307 --host-name=dc1 --host-ip=192.168.77.13 --adminpass="$adminpass" --option='interfaces=lo lan0' --option='bind interfaces only=yes'
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
samba-tool group add Readers
samba-tool group add Support
samba-tool group addmembers Readers Support
workerpass="W$(openssl rand -hex 16)!a"
outsiderpass="V$(openssl rand -hex 16)!a"
samba-tool user create worker1 "$workerpass"
samba-tool user create outsider1 "$outsiderpass"
samba-tool group addmembers Support worker1
install -d -m 0755 /srv/domain-docs
printf 'domain-document-001\n' > /srv/domain-docs/note.txt
cat >> /etc/samba/smb.conf <<'EOF'

[documents]
    path = /srv/domain-docs
    read only = yes
    valid users = @LAB\Readers
EOF
systemctl unmask samba-ad-dc
systemctl enable --now samba-ad-dc
for i in $(seq 1 30); do dig @192.168.77.13 dc1.lab.example +short | grep -q '192.168.77.13' && break; sleep 2; done
dig @192.168.77.13 _ldap._tcp.lab.example SRV +short
dig @192.168.77.13 dc1.lab.example +short | grep -x 192.168.77.13
for pair in "worker1:$workerpass" "outsider1:$outsiderpass"; do
  name=${pair%%:*};pass=${pair#*:}
  install -m 0600 /dev/null "/root/$name.auth"
  printf 'username = %s\npassword = %s\ndomain = LAB\n' "$name" "$pass" > "/root/$name.auth"
done
smbclient //192.168.77.13/documents -A /root/worker1.auth -c 'get note.txt /tmp/domain-read.txt'
cmp /tmp/domain-read.txt /srv/domain-docs/note.txt
if smbclient //192.168.77.13/documents -A /root/outsider1.auth -c 'ls'; then echo 'outsider admitted'; exit 1; fi
samba-tool group listmembers Readers
samba-tool group listmembers Support
samba-tool group removemembers Support worker1
if smbclient //192.168.77.13/documents -A /root/worker1.auth -c 'ls'; then echo 'new session retained removed group'; exit 1; fi
samba-tool user disable worker1
if smbclient //192.168.77.13/documents -A /root/worker1.auth -c 'ls'; then exit 1; fi
samba-tool user enable worker1
samba-tool group addmembers Support worker1
smbclient //192.168.77.13/documents -A /root/worker1.auth -c 'get note.txt /tmp/domain-read-again.txt'
cmp /tmp/domain-read-again.txt /srv/domain-docs/note.txt
samba-tool dbcheck --cross-ncs
printf '\nDOMAIN PASS: real directory, nested group, new session denial, old document\n'
