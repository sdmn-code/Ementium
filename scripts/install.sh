#!/bin/zsh
# Собирает Ementium (Release, Universal) и устанавливает в ~/Applications, перезапуская работающий процесс.
#
# Одна установленная копия — одно разрешение «Универсальный доступ» и правильная цель
# для «Открыть в программе». Подпись (Apple Development) стабильна между сборками,
# поэтому разрешение после переустановки сохраняется.
#
#   scripts/install.sh            — собрать, установить, запустить
#   scripts/install.sh --no-open  — собрать и установить, не запуская
set -euo pipefail
cd "${0:A:h}/.."

DEST="$HOME/Applications/Ementium.app"
BUILT="build/DerivedData/Build/Products/Release/Ementium.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Spotlight регистрирует найденные приложения в LaunchServices — папку сборки он индексировать не должен.
mkdir -p build && touch build/.metadata_never_index

# Всегда с чистой папки: инкрементальная сборка после изменения перечислений Swift собирала
# несовместимые части (тесты видели .step вместо .pass) — в установленное приложение это попасть не должно.
rm -rf build/DerivedData

echo "→ Сборка…"
xcodebuild -project Ementium.xcodeproj -scheme Ementium -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData -quiet build

echo "→ Установка в $DEST"
pkill -x Ementium 2>/dev/null && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# Промежуточные сборки не должны перехватывать «Открыть в программе».
for app in build/DerivedData/Build/Products/*/Ementium.app(N); do
  "$LSREGISTER" -u "$app" 2>/dev/null || true
done
"$LSREGISTER" -f "$DEST"

echo "→ Архитектуры: $(lipo -archs "$DEST/Contents/MacOS/Ementium")"

if [[ "${1:-}" != "--no-open" ]]; then
  open "$DEST"
  echo "→ Запущен. Иконка — в строке меню."
fi
