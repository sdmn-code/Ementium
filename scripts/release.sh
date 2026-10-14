#!/bin/zsh
# Сборка релиза Ementium: чистая Release-сборка (arm64), проверка подписи и песочницы сервиса,
# DMG с ярлыком «Программы» и контрольная сумма SHA-256. Результат — в build/release/.
#
# Подпись — сертификат Apple Development (без платной подписки Developer ID и нотаризации нет):
# при первом запуске macOS попросит «Всё равно открыть» в «Конфиденциальность и безопасность».
set -euo pipefail
cd "${0:A:h}/.."

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

echo "→ Сборка Release…"
xcodebuild -project Ementium.xcodeproj -scheme Ementium -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$OUT/DerivedData" build > "$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log"; echo "✗ Сборка не удалась, лог: $OUT/build.log"; exit 1; }

APP="$OUT/DerivedData/Build/Products/Release/Ementium.app"
SERVICE="$APP/Contents/XPCServices/EmentiumDecoder.xpc"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "→ Версия $VERSION ($BUILD), архитектуры: $(lipo -archs "$APP/Contents/MacOS/Ementium")"

echo "→ Проверка подписи…"
codesign --verify --deep --strict "$APP"
# Вывод — сначала в переменную: `grep -q` в конвейере закрыл бы его раньше времени, и pipefail счёл бы это ошибкой.
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
print -r -- "$SIGNATURE" | grep -E "^(Authority|TeamIdentifier)=" | head -2
for bundle in "$APP" "$SERVICE"; do
  # Hardened runtime у обоих; отладочного права get-task-allow в релизе быть не должно.
  INFO=$(codesign -dv "$bundle" 2>&1)
  [[ "$INFO" == *"(runtime)"* ]] || { echo "✗ Нет hardened runtime: $bundle"; exit 1; }
  ENTITLEMENTS=$(codesign -d --entitlements - "$bundle" 2>/dev/null || true)
  [[ "$ENTITLEMENTS" != *"get-task-allow"* ]] || { echo "✗ В релизе есть get-task-allow: $bundle"; exit 1; }
done
ENTITLEMENTS=$(codesign -d --entitlements - "$SERVICE" 2>/dev/null || true)
[[ "$ENTITLEMENTS" == *"com.apple.security.app-sandbox"* ]] || { echo "✗ Сервис декодирования без песочницы"; exit 1; }
echo "  подпись в порядке, у сервиса — песочница"

echo "→ DMG…"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Ementium-$VERSION.dmg"
# `hdiutil create` на macOS 27 устарел — `diskutil image create`; том внутри образа — APFS.
# Прогресс он пишет в поток ошибок — показываем вывод, только если не вышло.
DMG_LOG=$(diskutil image create from --format UDZO --volumeName "Ementium $VERSION" "$STAGE" "$DMG" 2>&1) \
  || { print -r -- "$DMG_LOG"; echo "✗ DMG не создан"; exit 1; }
hdiutil verify "$DMG" > /dev/null
(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
