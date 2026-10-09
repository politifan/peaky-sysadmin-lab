#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
test "$(hostname)" = node-a
test -f /etc/peaky-instance
printf '\n=== EXTENDED: SQLite backup and repeated event ===\n'
sqlite3 /home/student/peaky-queue.db 'PRAGMA journal_mode=WAL; CREATE TABLE deliveries(event_id TEXT PRIMARY KEY,delivered INTEGER NOT NULL DEFAULT 0); INSERT INTO deliveries VALUES("event-001",1);'
sqlite3 /home/student/peaky-queue.db '.backup /home/student/queue-copy.db'
sqlite3 /home/student/peaky-queue.db 'INSERT OR IGNORE INTO deliveries VALUES("event-001",1); INSERT INTO deliveries VALUES("event-002",0);'
test "$(sqlite3 /home/student/peaky-queue.db 'SELECT COUNT(*) FROM deliveries;')" = 2
test "$(sqlite3 /home/student/queue-copy.db 'PRAGMA integrity_check;')" = ok
test "$(sqlite3 /home/student/queue-copy.db 'SELECT event_id,delivered FROM deliveries;')" = 'event-001|1'
printf 'SQLite: backup old event preserved, new event outside copy, repeated PK unchanged\n'
printf '\n=== EXTENDED: inode exhaustion in own disposable image ===\n'
truncate -s 16M /var/lib/peaky-inodes.img
mkfs.ext4 -q -m 0 -N 128 /var/lib/peaky-inodes.img
mkdir /srv/peaky-inodes
mount -o loop /var/lib/peaky-inodes.img /srv/peaky-inodes
for i in $(seq 1 160); do touch "/srv/peaky-inodes/f-$i" 2>/dev/null || break; done
df -h /srv/peaky-inodes
df -i /srv/peaky-inodes
if touch /srv/peaky-inodes/last; then echo 'expected exhausted inode'; exit 1; fi
rm -- /srv/peaky-inodes/f-1
touch /srv/peaky-inodes/last
umount /srv/peaky-inodes
printf '\n=== EXTENDED: systemd resource drop-in and identity ===\n'
mkdir -p /etc/systemd/system/list-check.service.d
printf '[Service]\nCPUQuota=20%%\nMemoryMax=64M\n' > /etc/systemd/system/list-check.service.d/resource.conf
systemctl daemon-reload
systemctl show list-check.service -p User -p CPUQuotaPerSecUSec -p MemoryMax
systemctl start list-check.service
rm -- /etc/systemd/system/list-check.service.d/resource.conf
systemctl daemon-reload
printf '\nEXTENDED GUEST PASS\n'
