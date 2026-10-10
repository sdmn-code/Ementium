#!/bin/zsh
# Сборка и запуск FinderAXProbe.
#   ./run.sh watch   — ручная проверка, Ctrl+C — итог
#   ./run.sh auto    — автосценарий по режимам Finder
# Лог пишется в logs/.
set -euo pipefail
cd "${0:A:h}"

mode="${1:-watch}"
[[ $# -gt 0 ]] && shift

mkdir -p .build logs
swiftc -O -swift-version 5 -o .build/probe probe.swift
exec .build/probe "$mode" --testdata "$PWD/testdata" --log "logs/$(date +%Y%m%d-%H%M%S)-$mode.log" "$@"
