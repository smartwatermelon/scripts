#!/usr/bin/env bash
set -euo pipefail

INPUT="${1:-/tmp/dns-names.txt}"

if [[ ! -f "$INPUT" ]]; then
  echo "File not found: $INPUT" >&2
  exit 1
fi

printf "%-40s %-12s %-12s %s\n" "HOSTNAME" "RESOLVES" "CERT VALID" "DETAILS"
printf "%-40s %-12s %-12s %s\n" "--------" "--------" "----------" "-------"

while IFS= read -r host || [[ -n "$host" ]]; do
  [[ -z "$host" || "$host" == \#* ]] && continue

  # Check DNS resolution
  if ! host "$host" &>/dev/null; then
    printf "%-40s %-12s %-12s %s\n" "$host" "NO" "-" "DNS lookup failed"
    continue
  fi

  # Check HTTPS with certificate validation (5s timeout)
  output=$(curl -sI --max-time 5 "https://${host}/" 2>&1) && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    status=$(echo "$output" | head -1 | tr -d '\r')
    printf "%-40s %-12s %-12s %s\n" "$host" "YES" "YES" "$status"
  else
    err=$(echo "$output" | head -1 | tr -d '\r')
    printf "%-40s %-12s %-12s %s\n" "$host" "YES" "NO" "${err:-(rc=$rc)}"
  fi

done <"$INPUT"
