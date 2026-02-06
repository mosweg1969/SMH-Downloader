#!/usr/bin/env bash

awk '
BEGIN {
  CYAN="\033[36m"
  MAGENTA="\033[35m"
  RED="\033[1;31m"
  RESET="\033[0m"
  YELLOW="\033[33m"
  GREEN="\033[32m"
  BLUE="\033[34m"
}

$0 ~ /^MAIN/ {
    print YELLOW substr($0, 0, 12) GREEN substr($0, 13) RESET
    next
}

$0 ~ /^WARNING/ {
  print BLUE $0 RESET
  next
}

$0 ~ /^ERROR/ {
  print RED $0 RESET
  next
}

$0 ~ /^DATE/ {
  print CYAN "DATE" RESET substr($0,5)
  next
}

$0 ~ /^SUPPLEMENT/ {
  print MAGENTA "SUPPLEMENT" RESET substr($0,11)
  next
}

{ print }
'
