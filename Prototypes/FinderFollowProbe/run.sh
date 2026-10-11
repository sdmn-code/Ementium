#!/bin/zsh
# Сборка и запуск FinderFollowProbe.
#   ./run.sh auto     — автосценарий на тестовой папке
#   ./run.sh manual   — ⌃⌥Пробел в Finder запускает прогон на текущем окне
# Лог пишется в logs/.
set -euo pipefail
cd "${0:A:h}"

mode="${1:-auto}"
[[ $# -gt 0 ]] && shift

mkdir -p .build logs
swiftc -O -swift-version 5 -suppress-warnings -o .build/follow follow.swift
exec .build/follow "$mode" --log "logs/$(date +%Y%m%d-%H%M%S)-$mode.log" "$@"
