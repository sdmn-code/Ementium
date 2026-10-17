#!/bin/zsh
# Сборка и запуск LiveTextProbe; лог — в logs/ (в git не попадает).
#   ./run.sh measure [файлы…]
#   ./run.sh align [файл]
#   ./run.sh overlay [файл] [--follow]
set -euo pipefail
cd "${0:A:h}"
mkdir -p logs
swiftc -swift-version 5 -O probe.swift -o logs/probe
LOG="logs/${1:-measure}-$(date +%H%M%S).log"
OUT="$PWD/logs" ./logs/probe "$@" 2>&1 | tee "$LOG"
