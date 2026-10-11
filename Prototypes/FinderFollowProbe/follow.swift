// FinderFollowProbe — прототип подхода «Ementium следует за выделением Finder».
//
// Проверяет, можно ли листать, отправляя стрелки в Finder и читая новое выделение через AX,
// пока поверх экрана висит наш оверлей, а Finder остаётся активным:
//   • доходят ли синтетические стрелки до Finder в каждом виде и каким способом отправки;
//   • за сколько миллисекунд выделение меняется;
//   • что происходит на краю списка;
//   • переходит ли → в «значках» на следующую строку;
//   • не забирает ли оверлей фокус у Finder.
//
// Режимы:
//   auto   — сам открывает тестовую папку и прогоняет все виды;
//   manual — ждёт ⌃⌥Пробел в Finder и прогоняет тест на текущем окне как есть
//            (твоя сортировка, «Недавние», поиск — что угодно).
//
// Одноразовый исследовательский код, в приложение не переносится.

import AppKit
import ApplicationServices

// MARK: - Аргументы и лог

var mode = "auto"
var testFolder = FileManager.default.currentDirectoryPath + "/../FinderAXProbe/testdata/many"
var logPath: String?
do {
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("--") { mode = first; args.removeFirst() }
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--folder": testFolder = args[i + 1]; i += 1
        case "--log": logPath = args[i + 1]; i += 1
        default: print("Неизвестный аргумент \(args[i])"); exit(2)
        }
        i += 1
    }
}
testFolder = URL(fileURLWithPath: testFolder).standardizedFileURL.path

let start = DispatchTime.now().uptimeNanoseconds
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ from: UInt64) -> Double { Double(now() - from) / 1e6 }

var logHandle: FileHandle?
if let logPath {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    logHandle = FileHandle(forWritingAtPath: logPath)
}
let logLock = NSLock()
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    let line = String(format: "[%8.3f] ", Double(now() - start) / 1e9) + s
    print(line)
    fflush(stdout)
    logHandle?.write((line + "\n").data(using: .utf8)!)
}

// MARK: - AX

guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
    print("Finder не запущен"); exit(1)
}
let finderPID = finder.processIdentifier
let axFinder = AXUIElementCreateApplication(finderPID)
AXUIElementSetMessagingTimeout(axFinder, 1.0)

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func element(_ v: AnyObject?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func elements(_ v: AnyObject?) -> [AXUIElement]? {
    guard let a = v as? [AXUIElement], !a.isEmpty else { return nil }
    return a
}
func findURL(_ el: AXUIElement, _ depth: Int) -> URL? {
    if let u = attr(el, kAXURLAttribute) as? URL { return u }
    guard depth > 0, let kids = elements(attr(el, kAXChildrenAttribute)) else { return nil }
    for k in kids { if let u = findURL(k, depth - 1) { return u } }
    return nil
}

struct FinderState: Equatable {
    var view = "?"
    var names: [String] = []
    var window = "—"
}

func finderState() -> FinderState {
    var state = FinderState()
    if let w = element(attr(axFinder, kAXFocusedWindowAttribute)) {
        state.window = attr(w, kAXTitleAttribute) as? String ?? "—"
    }
    guard let focused = element(attr(axFinder, kAXFocusedUIElementAttribute)) else { return state }
    let role = attr(focused, kAXRoleAttribute) as? String ?? "?"
    switch attr(focused, kAXIdentifierAttribute) as? String {
    case "ListView": state.view = "список"
    case "IconView": state.view = "значки"
    case "GalleryView": state.view = "галерея"
    default: state.view = role == kAXListRole ? "колонки" : role
    }
    let items = elements(attr(focused, kAXSelectedRowsAttribute)) ?? elements(attr(focused, kAXSelectedChildrenAttribute)) ?? []
    state.names = items.compactMap { findURL($0, 2)?.lastPathComponent }
    return state
}

// MARK: - Отправка стрелок

enum Key: CGKeyCode { case left = 123, right = 124, down = 125, up = 126 }
let keyNames: [Key: String] = [.left: "←", .right: "→", .down: "↓", .up: "↑"]

enum Method: String, CaseIterable {
    case hid = "HID"          // как будто нажали на клавиатуре
    case session = "session"  // в поток событий сессии
    case pid = "pid"          // напрямую процессу Finder
}

func post(_ key: Key, via method: Method) {
    // Отдельное состояние источника: модификаторы, зажатые пользователем, не подмешиваются.
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.rawValue, keyDown: down) else { continue }
        event.flags = []
        switch method {
        case .hid: event.post(tap: .cghidEventTap)
        case .session: event.post(tap: .cgSessionEventTap)
        case .pid: event.postToPid(finderPID)
        }
    }
}

struct StepResult {
    let view: String
    let method: Method
    let key: Key
    let before: [String]
    let after: [String]
    let latency: Double?
    var moved: Bool { latency != nil }
}

/// Отправляет стрелку и ждёт до 600 мс, пока выделение не сменится (пустое — промежуточное, пропускаем).
func step(_ key: Key, via method: Method) -> StepResult {
    let before = finderState()
    let t0 = now()
    post(key, via: method)
    var after = before.names
    var latency: Double?
    while ms(t0) < 600 {
        usleep(3000)
        let names = finderState().names
        if !names.isEmpty, names != before.names {
            after = names
            latency = ms(t0)
            break
        }
    }
    let result = StepResult(view: before.view, method: method, key: key, before: before.names, after: after, latency: latency)
    log("   \(method.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(keyNames[key]!)  "
        + "\(before.names.joined(separator: ",")) → \(after.joined(separator: ","))  "
        + (latency.map { String(format: "%.0f мс", $0) } ?? "НЕ СДВИНУЛОСЬ"))
    usleep(150_000)
    return result
}

/// Стрелка «вперёд» для вида: в списке и колонках — ↓, в значках и галерее — →.
func forwardKey(for view: String) -> Key { ["список", "колонки"].contains(view) ? .down : .right }
func backwardKey(for view: String) -> Key { ["список", "колонки"].contains(view) ? .up : .left }

// MARK: - Оверлей (как у Ementium: поверх всего, клавиатуру не берёт)

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!.frame
let overlay = OverlayPanel(
    contentRect: NSRect(x: screen.midX - 300, y: screen.maxY - 190, width: 600, height: 120),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
)
overlay.level = .screenSaver
overlay.isOpaque = false
overlay.backgroundColor = NSColor.black.withAlphaComponent(0.8)
overlay.ignoresMouseEvents = true
overlay.hidesOnDeactivate = false
overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let label = NSTextField(wrappingLabelWithString: "")
label.textColor = .white
label.font = .systemFont(ofSize: 15)
label.frame = NSRect(x: 16, y: 10, width: 568, height: 100)
overlay.contentView?.addSubview(label)

func showOverlay(_ text: String) {
    DispatchQueue.main.async {
        label.stringValue = "FinderFollowProbe — оверлей не берёт клавиатуру\n" + text
        overlay.orderFrontRegardless()
    }
}
func hideOverlay() { DispatchQueue.main.async { overlay.orderOut(nil) } }

// MARK: - AppleScript (только на главном потоке)

@discardableResult
func appleScript(_ source: String) -> Bool {
    var ok = false
    DispatchQueue.main.sync {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log("   ⚠️ AppleScript: \(error[NSAppleScript.errorMessage] ?? error)") } else { ok = true }
    }
    return ok
}
func quoted(_ path: String) -> String { "(POSIX file \"\(path.replacingOccurrences(of: "\"", with: "\\\""))\" as alias)" }
func select(_ name: String) {
    appleScript("tell application \"Finder\" to set selection to {\(quoted(testFolder + "/" + name))}")
    usleep(400_000)
}

/// Проверка, что фокус по-прежнему у Finder, а не у нас.
func checkFocus(_ context: String) {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    log("   фокус (\(context)): активно \(front), окно Finder «\(finderState().window)»")
}

// MARK: - Сценарии

var results: [StepResult] = []
var wrapReport: [String] = []
var edgeReport: [String] = []

func runMethods(on view: String, reset: () -> Void) {
    for method in Method.allCases {
        reset()
        log(" • \(view), способ \(method.rawValue): 4 шага вперёд, 2 назад")
        for _ in 0..<4 { results.append(step(forwardKey(for: view), via: method)) }
        for _ in 0..<2 { results.append(step(backwardKey(for: view), via: method)) }
    }
}

func autoScenario() {
    let views = [("list view", "список"), ("column view", "колонки"), ("icon view", "значки"), ("flow view", "галерея")]
    appleScript("""
    tell application "Finder"
        activate
        make new Finder window to \(quoted(testFolder))
        set current view of front window to list view
    end tell
    """)
    usleep(1_200_000)
    for (asView, view) in views {
        showOverlay("Вид: \(view). Не трогай мышь и клавиатуру.")
        // Выделение задаём в «списке» — в «колонках» AppleScript его не ставит, а при смене вида оно сохраняется.
        let reset = {
            appleScript("tell application \"Finder\" to set current view of front window to list view")
            usleep(300_000)
            select("img-001.png")
            appleScript("tell application \"Finder\" to set current view of front window to \(asView)")
            usleep(700_000)
        }
        log("")
        log("=== Вид «\(view)»")
        runMethods(on: view, reset: reset)
        checkFocus("после вида «\(view)»")

        // Край: последний файл, шаг вперёд.
        appleScript("tell application \"Finder\" to set current view of front window to list view")
        usleep(300_000)
        select("img-150.png")
        appleScript("tell application \"Finder\" to set current view of front window to \(asView)")
        usleep(700_000)
        let edge = step(forwardKey(for: view), via: .session)
        edgeReport.append("\(view): на последнем файле «вперёд» — " + (edge.moved ? "сдвинулось на \(edge.after.joined())" : "не сдвинулось ✓"))

        if view == "значки" {
            reset()
            var path = [finderState().names.joined()]
            for _ in 0..<15 {
                post(.right, via: .session)
                usleep(200_000)
                path.append(finderState().names.joined())
            }
            wrapReport.append("значки, 15× →: " + path.joined(separator: " → "))
        }
        if view == "галерея" {
            reset()
            let down = step(.down, via: .session)
            wrapReport.append("галерея, ↓: " + (down.moved ? "сдвинулось на \(down.after.joined())" : "ничего не делает"))
        }
    }
    appleScript("tell application \"Finder\" to close front window")
    hideOverlay()
    summary()
}

func manualRun() {
    usleep(800_000)  // дать отпустить ⌃⌥
    let state = finderState()
    showOverlay("Вид: \(state.view), окно «\(state.window)». Не трогай клавиатуру.")
    log("")
    log("=== Ручной прогон: окно «\(state.window)», вид «\(state.view)», выделено \(state.names)")
    checkFocus("до")
    let original = state.names
    for method in Method.allCases {
        log(" • способ \(method.rawValue): 4 шага вперёд, 4 назад")
        for _ in 0..<4 { results.append(step(forwardKey(for: state.view), via: method)) }
        for _ in 0..<4 { results.append(step(backwardKey(for: state.view), via: method)) }
    }
    checkFocus("после")
    let finalNames = finderState().names
    log("   вернулись к исходному: \(finalNames == original ? "да ✓" : "нет — \(finalNames)")")
    hideOverlay()
    log("Готово. Можно выбрать другое окно/вид и снова нажать ⌃⌥Пробел. Ctrl+C — итог.")
}

func summary() {
    log("")
    log("===== ИТОГ =====")
    log("вид        | способ  | сдвинулось | задержка, мс (средн / макс)")
    var keys: [(String, Method)] = []
    for r in results where !keys.contains(where: { $0.0 == r.view && $0.1 == r.method }) { keys.append((r.view, r.method)) }
    for (view, method) in keys {
        let group = results.filter { $0.view == view && $0.method == method }
        let lat = group.compactMap(\.latency)
        let avg = lat.isEmpty ? 0 : lat.reduce(0, +) / Double(lat.count)
        log(view.padding(toLength: 10, withPad: " ", startingAt: 0) + " | "
            + method.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0) + " | "
            + "\(group.filter(\.moved).count) из \(group.count)".padding(toLength: 10, withPad: " ", startingAt: 0) + " | "
            + String(format: "%.0f / %.0f", avg, lat.max() ?? 0))
    }
    for line in edgeReport { log("Край — " + line) }
    for line in wrapReport { log(line) }
    if mode == "auto" { exit(0) }
}


// MARK: - Пачка стрелок (режим burst)

let mixedFolder = URL(fileURLWithPath: testFolder).deletingLastPathComponent().appendingPathComponent("mixed").path

/// Папка: картинка, 40 документов, картинка, 5 документов, картинка.
func makeMixedFolder() {
    let fm = FileManager.default
    try? fm.removeItem(atPath: mixedFolder)
    try? fm.createDirectory(atPath: mixedFolder, withIntermediateDirectories: true)
    let png = testFolder + "/img-001.png"
    for name in ["a-img.png", "c-img.png", "e-img.png"] { try? fm.copyItem(atPath: png, toPath: mixedFolder + "/" + name) }
    for i in 1...40 { fm.createFile(atPath: mixedFolder + String(format: "/b-doc-%02d.txt", i), contents: Data("x".utf8)) }
    for i in 1...5 { fm.createFile(atPath: mixedFolder + "/d-doc-\(i).txt", contents: Data("x".utf8)) }
}

func isImageName(_ name: String) -> Bool { name.hasSuffix(".png") }

/// Элементы вида и индекс выделенного: строки списка, дети колонки, элементы секций значков/галереи.
func viewItemsAndSelection() -> ([AXUIElement], Int?) {
    guard let focused = element(attr(axFinder, kAXFocusedUIElementAttribute)) else { return ([], nil) }
    var items: [AXUIElement]
    if let rows = elements(attr(focused, kAXRowsAttribute)) {
        items = rows
    } else {
        items = (elements(attr(focused, kAXChildrenAttribute)) ?? []).flatMap { child in
            attr(child, kAXRoleAttribute) as? String == kAXListRole ? elements(attr(child, kAXChildrenAttribute)) ?? [] : [child]
        }
    }
    let selected = elements(attr(focused, kAXSelectedRowsAttribute))?.first ?? elements(attr(focused, kAXSelectedChildrenAttribute))?.first
    let index = selected.flatMap { sel in items.firstIndex(where: { CFEqual($0, sel) }) }
    return (items, index)
}

/// Сколько шагов до ближайшей картинки в сторону `forward`, и её имя.
func lookahead(forward: Bool) -> (steps: Int, target: String)? {
    let (items, index) = viewItemsAndSelection()
    guard let index else { return nil }
    var i = index
    var steps = 0
    while true {
        i += forward ? 1 : -1
        steps += 1
        guard items.indices.contains(i) else { return nil }
        if let name = findURL(items[i], 2)?.lastPathComponent, isImageName(name) { return (steps, name) }
    }
}

func waitFor(_ target: String, timeout: Double) -> Double? {
    let t0 = now()
    while ms(t0) < timeout {
        if finderState().names == [target] { return ms(t0) }
        usleep(2000)
    }
    return nil
}

var burstReport: [String] = []

func burstJump(view: String, forward: Bool) {
    let key = forward ? forwardKey(for: view) : backwardKey(for: view)
    let from = finderState().names.joined()
    let t0 = now()
    guard let (steps, target) = lookahead(forward: forward) else {
        burstReport.append("\(view): \(from) \(forward ? "вперёд" : "назад") — картинок впереди нет (заглядывание \(String(format: "%.0f", ms(t0))) мс)")
        return
    }
    let lookMs = ms(t0)
    let t1 = now()
    for _ in 0..<steps { post(key, via: .pid) }
    let landed = waitFor(target, timeout: 4000)
    usleep(300_000)
    let final = finderState().names.joined()
    let line = "\(view): \(from) → \(target), \(steps) шагов пачкой: заглядывание \(String(format: "%.0f", lookMs)) мс, "
        + (landed.map { String(format: "Finder дошёл за %.0f мс", $0) } ?? "НЕ ДОШЁЛ за 4 с")
        + (final == target ? ", стоит точно ✓" : ", стоит на \(final) ✗")
    log("   " + line)
    burstReport.append(line)
}

func stepwiseJump(view: String) {
    // Как сейчас в Ementium: шаг, ждём ответ, снова шаг — пока не картинка.
    let key = forwardKey(for: view)
    let from = finderState().names.joined()
    let t0 = now()
    var steps = 0
    while steps < 60 {
        let r = step(key, via: .pid)
        steps += 1
        if let name = r.after.first, isImageName(name), r.moved { break }
        if !r.moved { break }
    }
    let line = "\(view): пошагово от \(from) до \(finderState().names.joined()): \(steps) шагов за \(String(format: "%.0f", ms(t0))) мс (с паузами прототипа 150 мс на шаг)"
    log("   " + line)
    burstReport.append(line)
}

func burstScenario() {
    makeMixedFolder()
    appleScript("""
    tell application "Finder"
        activate
        make new Finder window to \(quoted(mixedFolder))
        set current view of front window to list view
    end tell
    """)
    usleep(1_500_000)
    for (asView, view) in [("list view", "список"), ("column view", "колонки"), ("flow view", "галерея")] {
        showOverlay("Пачка стрелок, вид: \(view). Не трогай мышь и клавиатуру.")
        log("")
        log("=== Вид «\(view)»")
        appleScript("tell application \"Finder\" to set current view of front window to list view")
        usleep(300_000)
        appleScript("tell application \"Finder\" to set selection to {\(quoted(mixedFolder + "/a-img.png"))}")
        usleep(400_000)
        appleScript("tell application \"Finder\" to set current view of front window to \(asView)")
        usleep(900_000)
        log("   вид по AX: \(finderState().view), выделено \(finderState().names)")
        burstJump(view: view, forward: true)
        burstJump(view: view, forward: true)
        burstJump(view: view, forward: true)   // дальше картинок нет
        burstJump(view: view, forward: false)
        burstJump(view: view, forward: false)
    }
    // Для сравнения — пошагово в списке.
    appleScript("tell application \"Finder\" to set current view of front window to list view")
    usleep(300_000)
    appleScript("tell application \"Finder\" to set selection to {\(quoted(mixedFolder + "/a-img.png"))}")
    usleep(600_000)
    log("")
    log("=== Пошагово (как сейчас), список")
    stepwiseJump(view: "список")
    appleScript("tell application \"Finder\" to close front window")
    hideOverlay()
    log("")
    log("===== ИТОГ: ПАЧКА СТРЕЛОК =====")
    for line in burstReport { log(line) }
    exit(0)
}


// MARK: - Значки: последовательное листание (режим icons)

func position(of el: AXUIElement) -> CGPoint? {
    guard let v = attr(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

struct IconGrid {
    let collection: AXUIElement
    let sections: [AXUIElement]
    let items: [AXUIElement]
    let names: [String]
    let selectedIndex: Int?
}

func iconGrid() -> IconGrid? {
    guard let focused = element(attr(axFinder, kAXFocusedUIElementAttribute)) else { return nil }
    let sections = (elements(attr(focused, kAXChildrenAttribute)) ?? []).filter { attr($0, kAXRoleAttribute) as? String == kAXListRole }
    let items = sections.flatMap { elements(attr($0, kAXChildrenAttribute)) ?? [] }
    let names = items.map { findURL($0, 2)?.lastPathComponent ?? "?" }
    let selected = elements(attr(focused, kAXSelectedChildrenAttribute))?.first
    let index = selected.flatMap { sel in items.firstIndex(where: { CFEqual($0, sel) }) }
    return IconGrid(collection: focused, sections: sections, items: items, names: names, selectedIndex: index)
}

var iconReport: [String] = []

func describeGrid(_ g: IconGrid) {
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(g.collection, kAXSelectedChildrenAttribute as CFString, &settable)
    var sectionSettable = DarwinBoolean(false)
    if let first = g.sections.first { AXUIElementIsAttributeSettable(first, kAXSelectedChildrenAttribute as CFString, &sectionSettable) }
    let ys = g.items.compactMap { position(of: $0)?.y }
    let firstY = ys.first
    let columns = ys.prefix { $0 == firstY }.count
    let line = "значки: секций \(g.sections.count), подгружено \(g.items.count), столбцов \(columns), выделен №\(g.selectedIndex.map(String.init) ?? "?"); "
        + "AXSelectedChildren изменяемый: у коллекции \(settable.boolValue), у секции \(sectionSettable.boolValue)"
    log("   " + line)
    iconReport.append(line)
}

/// Способ B: поставить выделение через AX.
func jumpByAX(to target: String) {
    guard let g = iconGrid(), let ti = g.names.firstIndex(of: target) else {
        iconReport.append("B (AX): цель \(target) не подгружена"); return
    }
    let from = finderState().names.joined()
    let t0 = now()
    let value = [g.items[ti]] as CFArray
    var err = AXUIElementSetAttributeValue(g.collection, kAXSelectedChildrenAttribute as CFString, value)
    var whereSet = "коллекции"
    if err != .success, let section = g.sections.first {
        err = AXUIElementSetAttributeValue(section, kAXSelectedChildrenAttribute as CFString, value)
        whereSet = "секции"
    }
    let landed = waitFor(target, timeout: 1500)
    // Сдвинется ли Finder стрелкой уже от новой позиции — значит, его «текущий элемент» тоже сменился.
    usleep(200_000)
    post(.right, via: .pid)
    usleep(300_000)
    let afterArrow = finderState().names.joined()
    let line = "B (AX): \(from) → \(target): установка у \(whereSet) — \(err == .success ? "ok" : "ошибка \(err.rawValue)"), "
        + (landed.map { String(format: "Finder показал за %.0f мс", $0) } ?? "выделение НЕ сменилось")
        + "; затем → привело на \(afterArrow)"
    log("   " + line)
    iconReport.append(line)
    // Вернуть выделение на цель для следующего теста.
    post(.left, via: .pid)
    usleep(300_000)
}

/// Способ A: сначала по ряду до нужного столбца, потом вниз/вверх до нужного ряда.
func jumpByGrid(to target: String) {
    guard let g = iconGrid(), let si = g.selectedIndex, let ti = g.names.firstIndex(of: target),
          let ps = position(of: g.items[si]), let pt = position(of: g.items[ti]) else {
        iconReport.append("A (сетка): нет данных для \(target)"); return
    }
    let rowYs = Array(Set(g.items.compactMap { position(of: $0)?.y })).sorted()
    let colXs = Array(Set(g.items.compactMap { position(of: $0)?.x })).sorted()
    guard let rs = rowYs.firstIndex(of: ps.y), let rt = rowYs.firstIndex(of: pt.y),
          let cs = colXs.firstIndex(of: ps.x), let ct = colXs.firstIndex(of: pt.x) else {
        iconReport.append("A (сетка): позиции не совпали с сеткой"); return
    }
    let from = finderState().names.joined()
    let t0 = now()
    let dCol = ct - cs, dRow = rt - rs
    for _ in 0..<abs(dCol) { post(dCol > 0 ? .right : .left, via: .pid) }
    for _ in 0..<abs(dRow) { post(dRow > 0 ? .down : .up, via: .pid) }
    let landed = waitFor(target, timeout: 3000)
    usleep(200_000)
    let final = finderState().names.joined()
    let line = "A (сетка): \(from) → \(target): столбцов \(dCol), рядов \(dRow), "
        + (landed.map { String(format: "Finder дошёл за %.0f мс", $0) } ?? "НЕ ДОШЁЛ")
        + (final == target ? ", стоит точно ✓" : ", стоит на \(final) ✗") + String(format: " (всего %.0f мс)", ms(t0))
    log("   " + line)
    iconReport.append(line)
}

func iconsScenario() {
    makeMixedFolder()
    appleScript("""
    tell application "Finder"
        activate
        make new Finder window to \(quoted(mixedFolder))
        set current view of front window to icon view
        set arrangement of icon view options of front window to arranged by name
    end tell
    """)
    usleep(1_500_000)
    showOverlay("Значки: проверка последовательного листания. Не трогай мышь и клавиатуру.")
    func selectInList(_ name: String) {
        appleScript("tell application \"Finder\" to set current view of front window to list view")
        usleep(300_000)
        appleScript("tell application \"Finder\" to set selection to {\(quoted(mixedFolder + "/" + name))}")
        usleep(400_000)
        appleScript("tell application \"Finder\" to set current view of front window to icon view")
        usleep(900_000)
    }
    log("")
    log("=== Способ A: путь по сетке")
    selectInList("a-img.png")
    if let g = iconGrid() { describeGrid(g) }
    jumpByGrid(to: "c-img.png")
    jumpByGrid(to: "e-img.png")
    jumpByGrid(to: "c-img.png")
    jumpByGrid(to: "a-img.png")
    log("")
    log("=== Способ B: выделение через AX")
    selectInList("a-img.png")
    jumpByAX(to: "c-img.png")
    jumpByAX(to: "a-img.png")
    appleScript("tell application \"Finder\" to close front window")
    hideOverlay()
    log("")
    log("===== ИТОГ: ЗНАЧКИ =====")
    for line in iconReport { log(line) }
    exit(0)
}

// MARK: - Запуск

guard AXIsProcessTrusted() else {
    print("Нет доступа «Универсальный доступ» у терминала — см. README прототипа FinderAXProbe.")
    exit(1)
}
log("FinderFollowProbe: режим \(mode), Finder pid \(finderPID), папка \(testFolder)")

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigint.setEventHandler { summary(); exit(0) }
sigint.resume()

if mode == "auto" {
    log("Автосценарий: ~1,5 минуты. Не трогай мышь и клавиатуру.")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { autoScenario() }
} else if mode == "manual" {
    // ⌃⌥Пробел в Finder запускает прогон на текущем окне.
    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventKeycode) == 49,
           event.flags.contains(.maskControl), event.flags.contains(.maskAlternate) {
            DispatchQueue.global().async { manualRun() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                      callback: callback, userInfo: nil) else {
        print("Не удалось создать event tap"); exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    log("""
    Ручной режим. Открой в Finder любое окно (своя папка с сортировкой по типу, «Недавние», поиск, любой вид),
    кликни по файлу и нажми ⌃⌥Пробел. Прототип сам отправит 4 стрелки вперёд и 4 назад тремя способами.
    Ctrl+C в Терминале — итог.
    """)
} else if mode == "icons" {
    log("Значки: ~30 секунд. Не трогай мышь и клавиатуру.")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { iconsScenario() }
} else if mode == "burst" {
    log("Пачка стрелок: ~1 минута. Не трогай мышь и клавиатуру.")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { burstScenario() }
} else {
    print("Режим: auto | manual | burst | icons"); exit(2)
}

app.run()
