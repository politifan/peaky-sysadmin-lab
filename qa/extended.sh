#!/usr/bin/env bash
set -euo pipefail
./lab copy node-a qa/extended-guest.sh /tmp/extended-guest.sh
./lab ssh node-a 'sudo bash /tmp/extended-guest.sh' | tee evidence/extended-guest.log
printf '\n=== EXTENDED: wrong HTTP body denied, old body returned ===\n'
printf 'wrong-document\n' > .runtime/wrong.txt
if ./lab http --node node-a --expected .runtime/wrong.txt --out evidence/http-wrong.json; then exit 1; fi
./lab http --node node-a --expected files/index.txt --out evidence/http-return.json
printf '\n=== EXTENDED: partial Ansible failure and return ===\n'
./lab stop node-b
if (cd ansible && ansible-playbook portal.yml) > evidence/ansible-partial.log 2>&1; then exit 1; fi
grep -F UNREACHABLE evidence/ansible-partial.log
./lab start node-b
(cd ansible && ansible-playbook portal.yml --limit node-b && ansible-playbook portal.yml) | tee evidence/ansible-return.log
./lab http --node node-b --expected files/index.txt --out evidence/http-partial-return.json
printf '\n=== EXTENDED: encrypted variable, bounded no_log ===\n'
vaultpass=$(openssl rand -hex 20)
printf '%s\n' "$vaultpass" > .runtime/vault-password
printf 'training_token: "%s"\n' "$(openssl rand -hex 16)" > .runtime/training-vault.yml
chmod 0600 .runtime/vault-password .runtime/training-vault.yml
ansible-vault encrypt --vault-password-file .runtime/vault-password .runtime/training-vault.yml
(cd ansible && ansible-playbook secret.yml --vault-password-file ../.runtime/vault-password) > evidence/vault.log
./lab ssh node-a 'sudo test -s /etc/list-training-token && sudo stat -c "%a %U" /etc/list-training-token' | grep -x '600 root'
printf '\n=== EXTENDED: actual Kerberos client and GSSAPI LDAP ===\n'
./lab copy node-b files/krb5.conf /tmp/krb5.conf
./lab ssh node-b 'sudo install -m 0644 /tmp/krb5.conf /etc/krb5.conf'
./lab ssh dc1 'sudo cat /root/worker1.auth' | sed -n 's/^password = //p' > .runtime/worker-password
chmod 0600 .runtime/worker-password
./lab copy node-b .runtime/worker-password /home/student/.peaky-worker-password
./lab ssh node-b 'kinit worker1@LAB.EXAMPLE < /home/student/.peaky-worker-password && klist && ldapsearch -Y GSSAPI -H ldap://dc1.lab.example -b DC=lab,DC=example "(sAMAccountName=worker1)" dn && kdestroy && rm -- /home/student/.peaky-worker-password' | tee evidence/kerberos.log
grep -i 'dn:.*worker1' evidence/kerberos.log
printf '\n=== EXTENDED: live exporter, pending, firing and return ===\n'
./lab ssh node-a "sudo apt-get install -y prometheus-node-exporter; printf 'ARGS=\"--web.listen-address=192.168.77.11:9100\"\n' | sudo tee /etc/default/prometheus-node-exporter; sudo systemctl restart prometheus-node-exporter"
./lab ssh node-b 'sudo apt-get install -y prometheus'
for f in prometheus.yml list-alerts.yml; do ./lab copy node-b "files/$f" "/tmp/$f"; ./lab ssh node-b "sudo install -m 0644 /tmp/$f /etc/prometheus/$f"; done
./lab ssh node-b 'sudo promtool check rules /etc/prometheus/list-alerts.yml && sudo promtool check config /etc/prometheus/prometheus.yml && sudo systemctl restart prometheus'
for i in $(seq 1 30); do ./lab ssh node-b "curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up'" > evidence/prom-up.json; jq -e '.data.result[0].value[1]=="1"' evidence/prom-up.json && break; sleep 2; done
jq -e '.data.result[0].value[1]=="1"' evidence/prom-up.json
./lab ssh node-a 'sudo systemctl stop prometheus-node-exporter'
for i in $(seq 1 30); do ./lab ssh node-b 'curl -fsS http://127.0.0.1:9090/api/v1/alerts' > evidence/prom-pending.json; jq -e '.data.alerts[0].state=="pending"' evidence/prom-pending.json && break; sleep 1; done
jq -e '.data.alerts[0].state=="pending"' evidence/prom-pending.json
for i in $(seq 1 30); do ./lab ssh node-b 'curl -fsS http://127.0.0.1:9090/api/v1/alerts' > evidence/prom-firing.json; jq -e '.data.alerts[0].state=="firing"' evidence/prom-firing.json && break; sleep 2; done
jq -e '.data.alerts[0].state=="firing"' evidence/prom-firing.json
./lab http --node node-a --expected files/index.txt --out evidence/http-exporter-down.json
./lab ssh node-a 'sudo systemctl start prometheus-node-exporter'
for i in $(seq 1 30); do ./lab ssh node-b 'curl -fsS http://127.0.0.1:9090/api/v1/alerts' > evidence/prom-cleared.json; jq -e '.data.alerts|length==0' evidence/prom-cleared.json && break; sleep 2; done
jq -e '.data.alerts|length==0' evidence/prom-cleared.json
printf '\n=== EXTENDED: offline snapshot and full restored disk ===\n'
for key in operator-old operator-new; do ssh-keygen -q -t ed25519 -N '' -f ".runtime/$key"; ./lab copy node-a ".runtime/$key.pub" "/tmp/$key.pub"; done
./lab ssh node-a 'sudo install -d -m 0700 -o list-operator -g list-operator /home/list-operator/.ssh; sudo sh -c "cat /tmp/operator-old.pub /tmp/operator-new.pub > /home/list-operator/.ssh/authorized_keys"; sudo chown list-operator:list-operator /home/list-operator/.ssh/authorized_keys; sudo chmod 0600 /home/list-operator/.ssh/authorized_keys'
ssh -F .runtime/ssh-config -l list-operator -i .runtime/operator-old node-a 'true'
ssh -F .runtime/ssh-config -l list-operator -i .runtime/operator-new node-a 'sudo -n /usr/bin/systemctl --no-pager status nginx' > evidence/ssh-new-status.log
./lab ssh node-a 'sudo cp /home/list-operator/.ssh/authorized_keys /home/list-operator/.ssh/authorized_keys.before-rotation; sudo sh -c "cat /tmp/operator-new.pub > /home/list-operator/.ssh/authorized_keys"'
if ssh -F .runtime/ssh-config -l list-operator -i .runtime/operator-old node-a 'true' 2> evidence/ssh-old-denied.log; then exit 1; fi
ssh -F .runtime/ssh-config -l list-operator -i .runtime/operator-new node-a 'true'
printf 'SSH ROTATION PASS: new handshake succeeds, old handshake denied\n'
./lab stop node-a
./lab snapshot-vm node-a
./lab start node-a
./lab http --node node-a --expected files/index.txt --out evidence/http-snapshot.json
./lab stop node-a
./lab export-vm node-a backups/node-a-full.qcow2
qemu-img info --backing-chain backups/node-a-full.qcow2 | tee evidence/full-image-info.txt
if grep -F 'backing file:' evidence/full-image-info.txt; then exit 1; fi
./lab start node-a
./lab ssh node-a 'printf after-copy > ~/after-copy.txt'
./lab stop node-a
if ./lab restore-vm node-b backups/node-a-full.qcow2; then exit 1; fi
./lab restore-vm node-a backups/node-a-full.qcow2
./lab ssh node-a 'test ! -e ~/after-copy.txt && test -f ~/queue-copy.db && echo "old state returned; post-copy marker absent"'
test -f .runtime/node-a/disk.qcow2
./lab http --node node-a --expected files/index.txt --out evidence/http-cold-restore.json
printf '\nEXTENDED ROUTE PASS\n'
