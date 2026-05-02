#!/usr/bin/env bash
# shellcheck shell=bash
# parse-ports.sh — parse /etc/pi-monitor-light/ports.conf
# Format per line: <kernel-device> <name> <baud>
# Lines starting with # are ignored. Blank lines are ignored. Max 4 ports.
# Emits one validated line per port to stdout.

parse_ports() {
  local file=$1
  if [ ! -f "$file" ]; then
    echo "parse_ports: file not found: $file" >&2
    return 2
  fi

  local count=0
  local seen=''
  local dev name baud rest
  while read -r dev name baud rest; do
    case $dev in ''|\#*) continue ;; esac
    case $dev in
      ttyUSB[0-9]*|ttyACM[0-9]*) ;;
      *) echo "parse_ports: invalid device name (must be ttyUSB<n> or ttyACM<n>): $dev" >&2
         return 3 ;;
    esac
    if [ -z "$name" ] || [ -z "$baud" ]; then
      echo "parse_ports: malformed line: $dev $name $baud" >&2
      return 3
    fi
    case $name in
      *[!A-Za-z0-9_-]*|'')
        echo "parse_ports: invalid name (allowed chars: A-Z a-z 0-9 _ -): $name" >&2
        return 3 ;;
    esac
    case $baud in *[!0-9]*)
      echo "parse_ports: invalid baud (not numeric): $baud" >&2
      return 4
    ;; esac
    case $rest in
      ''|\#*) ;;
      *) echo "parse_ports: trailing garbage on line: $dev $name $baud $rest" >&2
         return 3 ;;
    esac
    count=$((count + 1))
    if [ "$count" -gt 4 ]; then
      echo "parse_ports: max 4 ports allowed" >&2
      return 5
    fi
    case " $seen " in
      *" $name "*)
        echo "parse_ports: duplicate name: $name" >&2
        return 6 ;;
    esac
    seen="$seen $name"
    echo "$dev $name $baud"
  done < "$file"
}

# If sourced, expose the function. If executed directly, run on $1.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ $# -lt 1 ]; then
    echo "Usage: parse-ports.sh <ports.conf>" >&2
    exit 64
  fi
  parse_ports "$1"
fi
