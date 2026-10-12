#!/bin/zsh
# Сборка и запуск FinderTrashProbe. Лог — в logs/.
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build logs
swiftc -O -swift-version 5 -suppress-warnings -o .build/trash trash.swift
exec .build/trash --log "logs/$(date +%Y%m%d-%H%M%S).log"
