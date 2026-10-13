#!/usr/bin/env bash
set -eu -o pipefail
# FizzBuzz : print integers 1..100
# multiples of 3, print Fizz instead
# multiples of 5, print Buzz instead
# multiple of both 3 and 5, print FizzBuzz instead

for N in {1..100}; do
  if [[ ($(("${N}" % 3)) == 0) && ($(("${N}" % 5)) == 0) ]]; then
    echo "FizzBuzz (${N})"
    continue
  elif [[ $(("${N}" % 3)) == 0 ]]; then
    echo "Fizz (${N})"
    continue
  elif [[ $(("${N}" % 5)) == 0 ]]; then
    echo "Buzz (${N})"
    continue
  else
    echo "${N}"
  fi
done
