#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
chmod +x lab
./lab up advanced
./lab status
for f in index.txt list-portal.conf list-check.sh list-check.service list-check.timer; do ./lab copy node-a "files/$f" "/tmp/$f"; done
./lab copy node-a qa/basic.sh /tmp/basic.sh
./lab ssh node-a 'sudo bash /tmp/basic.sh'
./lab http --node node-a --expected files/index.txt --out evidence/http-before.json
./lab ssh node-a 'sudo reboot' || true
for i in $(seq 1 90); do if ./lab ssh node-a 'test -f /var/lib/peaky-ready && systemctl is-active nginx' 2>/dev/null; then break; fi; sleep 3; done
./lab http --node node-a --expected files/index.txt --out evidence/http-after-reboot.json
./lab ssh node-a 'sudo cat /tmp/basic-evidence.log' > evidence/basic.log
./lab copy node-a qa/advanced.sh /tmp/advanced.sh
./lab ssh node-a 'sudo bash /tmp/advanced.sh'
./lab ssh node-a 'sudo cat /tmp/advanced-evidence.log' > evidence/advanced.log
pushd ansible
ansible-playbook portal.yml | tee ../evidence/ansible-first.log
ansible-playbook portal.yml | tee ../evidence/ansible-repeat.log
grep 'changed=0' ../evidence/ansible-repeat.log | grep node-a
grep 'changed=0' ../evidence/ansible-repeat.log | grep node-b
popd
./lab http --node node-b --expected files/index.txt --out evidence/http-b.json
./lab ssh node-b 'curl -fsS http://192.168.77.11:8080/index.txt' | cmp - files/index.txt
# A firewall on the guest LAN only: SSH via NAT remains available.
./lab ssh node-a "sudo nft add table inet peaky; sudo nft 'add chain inet peaky input { type filter hook input priority 0; policy accept; }'; sudo nft add rule inet peaky input iifname lan0 tcp dport 8080 reject"
if ./lab ssh node-b 'curl -fsS --max-time 3 http://192.168.77.11:8080/index.txt'; then exit 1; fi
./lab http --node node-a --expected files/index.txt --out evidence/http-nat.json
./lab ssh node-a 'sudo nft list table inet peaky; sudo nft delete table inet peaky'
./lab ssh node-b 'curl -fsS http://192.168.77.11:8080/index.txt' | cmp - files/index.txt
./lab copy dc1 qa/domain.sh /tmp/domain.sh
./lab ssh dc1 'sudo bash /tmp/domain.sh'
./lab ssh dc1 'sudo cat /tmp/domain-evidence.log' > evidence/domain.log
./lab ssh node-b 'dig @192.168.77.13 _ldap._tcp.lab.example SRV +short' | tee evidence/domain-dns-from-client.txt
grep 'dc1.lab.example' evidence/domain-dns-from-client.txt
printf '\nROUTE PASS: three actual VMs, old data, reboot, LAN, AD, Ansible, restore\n'
