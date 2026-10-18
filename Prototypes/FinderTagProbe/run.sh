#!/bin/zsh
# Сборка и запуск FinderTagProbe; лог — в logs/, тестовые файлы — в testdata/ (в git не попадают).
#   ./run.sh auto | labels | setup | toggle <файл> <1…7> | show <файл>
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build logs testdata
swiftc -O -swift-version 5 -suppress-warnings -o .build/tags tags.swift
LOG="logs/${1:-auto}-$(date +%H%M%S).log"
./.build/tags "$@" 2>&1 | tee "$LOG"
