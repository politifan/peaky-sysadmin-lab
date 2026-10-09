#!/usr/bin/env bash
set -euo pipefail
expected=/srv/list-portal/index.txt
actual=$(mktemp)
trap 'rm -f -- "$actual"' EXIT
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/index.txt > "$actual"
cmp -- "$expected" "$actual"
printf 'Portal document verified\n'
