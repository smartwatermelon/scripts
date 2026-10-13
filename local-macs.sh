#!/usr/bin/env bash
set -eu
#pipefail triggers on expected nonzero returns from piped commands, so is not used in this script
#exclude localhost name and any hostnames with spaces

perl -e 'alarm 3; exec @ARGV' dns-sd -B _ssh._tcp. 2>/dev/null |
  awk '$2 == "Add" {
    name = $7
    for (i = 8; i <= NF; i++) name = name " " $i
    if (!seen[name]++) print name
  }' |
grep -Ev "($HOSTNAME| )" |  sort -f
