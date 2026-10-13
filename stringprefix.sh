#!/usr/bin/env bash
set -euo pipefail

# Given an array of strings, determine the longest prefix that appears at least twice.

# For example:

# a = ["basic", "anchor", "bass", "bandage", "anchovy"]

# The longest common prefix here is “ancho”.

a=("basic" "anchor" "bass" "bandage" "anchovy")
if [ $# -eq 1 ]; then
  printf '%s\n' "syntax: $0 <word1> <word2> [...]
	(at least two words, or no words for the default set)"
  exit 1
elif [ $# -gt 1 ]; then
  a=("$@")
fi
aLen="${#a[@]}"
longestMatch=""

#	loop through array by numbered element; stop one before
#		end because we don't need to compare the last element to itself
for aElm in $(seq 0 $((${aLen} - 2))); do

  #	what array element is at this index?
  printf '%s\n' "testing ${a[${aElm}]}"

  #	loop through array from (this element plus 1)
  for aElmNextElm in $(seq $((${aElm} + 1)) $((${aLen} - 1))); do

    #	clear any previous matches
    thisMatch=""

    #	loop through this array element by string index
    for ((i = 0; i < ${#a[${aElm}]}; i++)); do

      #	character at this index
      aElmChar="${a[${aElm}]:${i}:1}"

      #	does the character of this array element at this index match the
      #		character of the next array element at this index?
      if [ "${aElmChar}" == "${a[${aElmNextElm}]:${i}:1}" ]; then
        printf '%s\n' "${aElmChar} matches character ${i} in ${a[aElm]} and ${a[aElmNextElm]}"

        #	concatenate to this set of matches
        thisMatch+="${aElmChar}"

        #	if this set of matches is longer than the current longest set,
        #		replace the longest set
        if [ "${#thisMatch}" -gt "${#longestMatch}" ]; then
          longestMatch="${thisMatch}"
        fi
      else
        #	mismatch: stop extending this prefix comparison
        break
      fi
    done
  done
done
printf '%s\n' "the longest match is: ${longestMatch}"
