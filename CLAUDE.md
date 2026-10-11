# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Состояние проекта

Remote — GitHub `sdmn-code/Ementium`. Реализованы v0.1 (оверлей, навигация, `open -a`), v0.2 (перехват Пробела в Finder, кэш Finder через AXObserver, разрешение, иконка в строке меню) и v0.2.2 (листание вслед за выделением Finder). Кэша изображений (`ImageCache`), настроек и автозапуска **ещё нет** — в README они описаны как план с пометками версий.

Перед ссылкой на любой тип из README проверяй, существует ли он. Меняешь структуру или поведение — обновляй README.

## Что это

Ementium — agent-приложение для macOS (`LSUIElement`), подменяющее Quick Look для изображений: Пробел в Finder открывает выделенную картинку полноэкранным оверлеем, стрелки листают изображения каталога, Esc закрывает. Нет Dock-иконки, нет меню; единственный UI — окно настроек. Процесс работает постоянно: Esc закрывает только окно просмотра, выход — через настройки или menu bar. Настройки открываются по `⌘,` только в просмотре (обрабатывается самим окном просмотра) и при повторном запуске `.app` (`applicationShouldHandleReopen`).

## Сборка

Xcode 27, Swift 6.4. Обычный `Ementium.xcodeproj` (формат Xcode 27) с синхронизируемыми папками: новый файл в `Ementium/` или `EmentiumTests/` попадает в target сам, `project.pbxproj` для этого не трогать. Минимальная версия — macOS 14.

```bash
xcodebuild -project Ementium.xcodeproj -scheme Ementium build     # Debug
xcodebuild -project Ementium.xcodeproj -scheme Ementium test      # Swift Testing
xcodebuild -project Ementium.xcodeproj -scheme Ementium -configuration Release \
  -destination 'generic/platform=macOS' build                     # Universal
```

**Инкрементальная сборка может врать.** После добавления варианта в перечисление (`ViewerKeyAction.zoom`) тесты на инкрементальной сборке массово падали с бессмысленными значениями (`.step` вместо `.pass`), а на чистой — проходили. Странные падения после изменения типов — сначала прогнать на чистой папке (`-derivedDataPath` в новую). `install.sh` всегда собирает с нуля.

Без `-destination 'generic/platform=macOS'` xcodebuild собирает только архитектуру этого Mac, хотя `ARCHS` в проекте — `arm64 x86_64`. Проверка: `lipo -archs …/Ementium.app/Contents/MacOS/Ementium`.

Песочница и hardened runtime — build settings (`ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME = YES`), файла `.entitlements` нет. `Info.plist` — частичный (только `CFBundleDocumentTypes`), остальное генерируется из `INFOPLIST_KEY_*`; в синхронизируемой папке он исключён из ресурсов через exception set.

Подпись — Apple Development, Personal Team `JW5WYVU2JQ` (бесплатный аккаунт). Developer ID и нотаризации для v1.0 пока нет.

**Swift 6 и изоляция.** В app-target `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` и approachable concurrency: всё по умолчанию на главном акторе, а `nonisolated async` выполняется на акторе вызывающего. Чистая логика (`ImageDirectory`, `ViewerCommand`) помечена `nonisolated`, чтобы её можно было тестировать и звать откуда угодно. Фоновая работа — `@concurrent` (см. `ImageLoader.load`), иначе декодирование уйдёт на главный поток.

**Установка и запуск.** `scripts/install.sh` — единственный способ ставить приложение для проверки перехвата: собирает Release, кладёт одну копию в `~/Applications`, снимает регистрацию промежуточных сборок в LaunchServices (иначе «Открыть в программе» ведёт в DerivedData) и запускает. `--no-open` — без запуска. `build/` помечен `.metadata_never_index`: Spotlight иначе заново регистрирует найденные там `.app`. Разрешение «Универсальный доступ» привязано к подписи (Apple Development, стабильна) и переживает переустановку.

**Запуск для проверки оверлея без перехвата.** `open -a <путь к .app> файл`. Оверлей перекрывает **весь экран пользователя** поверх всех окон — предупреждай перед запуском и закрывай `pkill -x Ementium`. Наличие окна без скриншота: `CGWindowListCopyWindowInfo` по PID (bounds, layer, alpha). Логи — `/usr/bin/log show --predicate 'subsystem == "io.github.sdmn-code.Ementium"' --info`: в zsh голое `log` — встроенная команда оболочки.

## Архитектура: ключевые ограничения

**Три потока.** Главный: `AppDelegate`, просмотр, меню, разрешения. `FinderBridge` и `KeyInterceptor` — каждый на своём `RunLoopThread`, чтобы AX-запросы к занятому Finder (до сотен мс) не блокировали ни UI, ни event tap. Общаются только через `InterceptionState` (снимок под `OSAllocatedUnfairLock`). Решение о поглощении — чистая `InterceptionPolicy.decide`, покрыта тестами; при любом сомнении (снимок устарел, идёт дебаунс, фокус в тексте) — пропускать Пробел. Пока открыт просмотр, `isViewerVisible = true` и Пробел не перехватывается: Finder остаётся активным, а Пробел должен дойти до панели просмотра.

**Листание вслед за Finder (режим «следовать»).** Один файл, открытый Пробелом: панель просмотра не берёт клавиатуру (`ViewerPanel.acceptsKeyboard = false`), Finder остаётся активным, все нажатия разбирает `KeyInterceptor` через `InterceptionPolicy.followingAction` — только пока `isViewerVisible && isFollowingFinder && isFinderFrontmost`, иначе клавиатура в другом приложении была бы проглочена. Стрелки уходят в `FinderBridge.step` → заглядывание по элементам вида (`AXRows`; в значках/галерее порядок на всякий случай восстанавливается по координатам — экранный порядок в AX не гарантирован) → пачка стрелок `postToPid` до ближайшей картинки → новое выделение из AX → `onShow`. Автомат — чистый `FinderNavigation` (режимы idle/stepping/jumping/returning), покрыт тестами. Подводные камни, найденные прототипами и ревью: в «значках» → не переносится на новую строку (путь по сетке — `IconGridPath`), а слепая → из короткого последнего ряда уводит на значок выше — поэтому на краю ничего не слать; Finder создаёт элементы значков/галереи лениво; пока пачка в полёте, новое нажатие откладывать (`queuedStep`); таймаут края сначала перечитывает выделение. Системные сочетания — из `com.apple.symbolichotkeys` (`SystemShortcuts`), пользователь мог их переназначить. Несколько файлов и `open -a` — режим «свой список» (`ImageDirectory`, панель берёт клавиатуру).

Эти вещи определяют устройство кода и не выводятся из отдельных файлов.

**CGEventTap должен отвечать мгновенно.** Решение «поглотить Пробел или пропустить» принимается синхронно в callback. Любая блокирующая работа внутри — и система отключит tap с `kCGEventTapDisabledByTimeout`. Поэтому в callback **никаких межпроцессных вызовов**, в том числе Accessibility-запросов к Finder: прототип намерил до 290 мс на `AXFocusedUIElement`, когда Finder занят. Tap нужно уметь переподключать после отключения.

**Решение: кэш состояния Finder через `AXObserver`.** `FinderBridge` подписывается на уведомления Finder о смене фокуса и выделения, с задержкой ~50 мс обновляет кэш (фокус в текстовом поле? есть ли среди выделенных изображения?), а callback только читает кэш. Изображение — поглощаем; не-изображение, текстовое поле, неготовый или неактуальный кэш — пропускаем Пробел в Finder, и открывается родной Quick Look. Своя `QLPreviewPanel` и ресинтез Пробела отвергнуты.

Схема подтверждена прототипом `Prototypes/FinderAXProbe` (только на macOS 27; его README — источник фактов о структуре AX у Finder). Подписка — на элемент приложения Finder. Выделение: `AXFocusedUIElement` → `AXSelectedRows` (список, `AXOutline`) или `AXSelectedChildren` (значки, колонки, галерея, рабочий стол, результаты поиска) → `AXURL` у элемента или его потомка не глубже 2 уровней. **Apple Events не используются**, разрешения Automation нет: AX отдаёт полные пути, а Apple Events медленнее в 20–30 раз и местами врут. Известное ограничение: в колонках 100–250 мс после клика выделение пустое — Пробел уходит в Quick Look, это принято.

**Порядок листания** — всегда порядок окна Finder (следуем за его выделением). Не возвращайся к угадыванию сортировки или эвристикам по заголовку окна: это было опробовано и отвергнуто (сортировку по типу угадать не удалось; эксперимент удалён). Несколько выделенных файлов — только они, по имени.

**Никакого App Sandbox и никакого Mac App Store.** `CGEventTap` и чтение интерфейса Finder через Accessibility несовместимы с песочницей. Распространение только через Developer ID + нотаризацию (`notarytool`).

**Разрешения привязаны к подписи.** Нужны Accessibility (`AXIsProcessTrustedWithOptions`) и, возможно, Input Monitoring (`CGPreflightListenEventAccess`). При разработке подпись меняется, и macOS «забывает» выданный доступ — приложение придётся удалять из списка в Системных настройках и выдавать доступ заново. Учитывай это при отладке: «не работает перехват» чаще означает слетевшее разрешение, а не баг в коде.

**Декодирование — через thumbnail, не через загрузку оригинала.** `CGImageSourceCreateThumbnailAtIndex` с ограничением по размеру экрана и `kCGImageSourceCreateThumbnailWithTransform` для EXIF-ориентации. Иначе RAW и большие фото съедят память. Кэш держит окно ±N вокруг текущего изображения.

**AppKit для оверлея, SwiftUI для настроек.** Окну просмотра нужен точный контроль уровня окна, фокуса и обработки клавиш — на SwiftUI это не делается. Настройки — `Settings` scene + `@AppStorage`.

**Тип файла — только через `UTType` (`conforms(to: .image)`)**, никогда по своему списку расширений. AX-кэш даёт полный URL, тип берётся из `URLResourceValues.contentType`. Сортировка каталога — `localizedStandardCompare`, чтобы совпадать с Finder.

## Тестирование

Ключевые части (event tap, AXObserver на Finder, оверлей поверх всех окон) требуют живого Finder и выданных разрешений — юнит-тестами не покрываются. Автотестами (Swift Testing, `EmentiumTests/`) покрыты `ImageDirectory`, `ImageLoader` (на сгенерированных картинках), `ViewerCommand`, `ViewerView.fittedRect`, `InterceptionPolicy` (поглощение Пробела и разбор клавиш в режиме «следовать»), `SystemShortcuts` (на копии реальных настроек), `SwallowedKeys`, `FinderNavigation` (автомат листания на поддельном Finder) и `IconGridPath`; дальше — `ImageCache` (окно предзагрузки). Тестовые файлы — пустые, тип определяется по расширению. Внутри `#expect` нельзя вызывать `mutating`-методы — выноси результат в `let`. Остальное — ручная проверка; v0.1 по дорожной карте специально начинается с открытия файла из командной строки, чтобы оверлей можно было проверять без перехвата.

## Язык

README и вся документация — на русском. Пиши документацию и коммиты по-русски, идентификаторы в коде — по-английски.
