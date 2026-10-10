// FinderAXProbe — прототип v0.1.
//
// Проверяет, можно ли держать кэш состояния Finder через AXObserver:
// приходят ли уведомления о смене фокуса и выделения, какие атрибуты Finder
// отдаёт для выделенных файлов в разных режимах отображения, сколько стоят
// AX-запросы и как часто сыплются уведомления.
//
// Режимы:
//   watch — слушает Finder, пользователь кликает руками, Ctrl+C — итог;
//   auto  — сам прогоняет режимы отображения и выделения через Apple Events;
//   gen   — только создаёт тестовую папку.
//
// Это одноразовый исследовательский код, в приложение он не переносится.

import AppKit
import ApplicationServices
import UniformTypeIdentifiers

// MARK: - Аргументы

var mode = "watch"
var testDataPath = FileManager.default.currentDirectoryPath + "/testdata"
var logPath: String?
var debounceMs = 50.0
var compareWithAppleEvents = true

do {
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("--") { mode = first; args.removeFirst() }
    var i = 0
    while i < args.count {
        let a = args[i]
        let next = i + 1 < args.count ? args[i + 1] : nil
        switch a {
        case "--testdata": testDataPath = next ?? testDataPath; i += 1
        case "--log": logPath = next; i += 1
        case "--debounce": debounceMs = Double(next ?? "") ?? debounceMs; i += 1
        case "--no-ae": compareWithAppleEvents = false
        default: print("Неизвестный аргумент: \(a)"); exit(2)
        }
        i += 1
    }
}

// MARK: - Лог и замеры

let startNs = DispatchTime.now().uptimeNanoseconds
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(since t0: UInt64) -> Double { Double(now() - t0) / 1e6 }

var logHandle: FileHandle?
if let logPath {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    logHandle = FileHandle(forWritingAtPath: logPath)
}

func log(_ s: String) {
    let t = Double(now() - startNs) / 1e9
    let line = String(format: "[%8.3f] ", t) + s
    print(line)
    fflush(stdout)
    logHandle?.write((line + "\n").data(using: .utf8)!)
}

struct Stat { var samples: [Double] = [] }
var stats: [String: Stat] = [:]
var recording = true

func record(_ key: String, _ value: Double) {
    guard recording else { return }
    stats[key, default: Stat()].samples.append(value)
}

// MARK: - Обёртки над AX

func axErr(_ e: AXError) -> String {
    switch e {
    case .success: return "ok"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notificationAlreadyRegistered: return "alreadyRegistered"
    case .cannotComplete: return "cannotComplete"
    case .notImplemented: return "notImplemented"
    case .attributeUnsupported: return "attributeUnsupported"
    case .noValue: return "noValue"
    case .invalidUIElement: return "invalidUIElement"
    case .apiDisabled: return "apiDisabled"
    default: return "AXError(\(e.rawValue))"
    }
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    let t0 = now()
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    record(name, ms(since: t0))
    return err == .success ? v : nil
}

func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

func element(_ v: AnyObject?) -> AXUIElement? {
    guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func elements(_ v: AnyObject?) -> [AXUIElement]? { v as? [AXUIElement] }

func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute) ?? "?" }

func roleKey(_ el: AXUIElement) -> String {
    role(el) + "/" + (str(el, kAXSubroleAttribute) ?? "-")
}

func short(_ v: AnyObject?) -> String {
    guard let v else { return "—" }
    if CFGetTypeID(v) == AXUIElementGetTypeID() { return "<\(roleKey(v as! AXUIElement))>" }
    if CFGetTypeID(v) == AXValueGetTypeID() { return "AXValue" }
    if let u = v as? URL { return u.absoluteString }
    if let s = v as? String { return "\"" + s.prefix(70) + (s.count > 70 ? "…" : "") + "\"" }
    if let n = v as? NSNumber { return n.stringValue }
    if let a = v as? [AnyObject] { return "[\(a.count) шт.]" }
    return String(describing: type(of: v))
}

var dumpedRoles = Set<String>()

// Один раз на каждую комбинацию роль/подроль печатает все атрибуты элемента —
// так видно, что Finder вообще отдаёт в этом режиме.
func dumpOnce(_ el: AXUIElement, label: String) {
    let key = roleKey(el)
    guard !dumpedRoles.contains(key) else { return }
    dumpedRoles.insert(key)
    recording = false
    defer { recording = true }
    var names: CFArray?
    AXUIElementCopyAttributeNames(el, &names)
    log("   ⓘ атрибуты \(label) \(key):")
    for n in (names as? [String]) ?? [] {
        log("       \(n) = \(short(attr(el, n)))")
    }
}

// MARK: - Finder

guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
    print("Finder не запущен")
    exit(1)
}
let finderPid = finder.processIdentifier
let app = AXUIElementCreateApplication(finderPid)
AXUIElementSetMessagingTimeout(app, 2.0)

// MARK: - Снимок состояния Finder

struct Item {
    let name: String?
    let url: URL?
    let via: String
    var isImage: Bool? {
        if let url, let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return t.conforms(to: .image)
        }
        guard let name else { return nil }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let t = UTType(filenameExtension: ext) else { return nil }
        return t.conforms(to: .image)
    }
}

struct Snapshot {
    let at: UInt64
    let focus: String
    let isText: Bool
    let source: String
    let items: [Item]
    let totalMs: Double
    var names: Set<String> { Set(items.compactMap { $0.name }) }
}

let selectionAttrs = [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute, kAXSelectedCellsAttribute]
let nameAttrs = [kAXFilenameAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

func findURL(_ el: AXUIElement, _ path: String, _ depth: Int) -> (URL, String)? {
    if let u = attr(el, kAXURLAttribute) as? URL { return (u, path + ".AXURL") }
    guard depth > 0, let kids = elements(attr(el, kAXChildrenAttribute)) else { return nil }
    for k in kids {
        if let r = findURL(k, path + ">" + role(k), depth - 1) { return r }
    }
    return nil
}

func findName(_ el: AXUIElement, _ path: String, _ depth: Int) -> (String, String)? {
    for a in nameAttrs {
        if let s = str(el, a), !s.isEmpty { return (s, path + "." + a) }
    }
    guard depth > 0, let kids = elements(attr(el, kAXChildrenAttribute)) else { return nil }
    for k in kids {
        if let r = findName(k, path + ">" + role(k), depth - 1) { return r }
    }
    return nil
}

func identify(_ item: AXUIElement) -> Item {
    let r = role(item)
    if let (u, via) = findURL(item, r, 2) { return Item(name: u.lastPathComponent, url: u, via: via) }
    if let (n, via) = findName(item, r, 2) { return Item(name: n, url: nil, via: via) }
    return Item(name: nil, url: nil, via: "\(r): имя не найдено")
}

// Ищет выделение, поднимаясь от сфокусированного элемента к окну.
func findSelection(from start: AXUIElement) -> (AXUIElement, String, [AXUIElement])? {
    var cur: AXUIElement? = start
    var firstEmpty: (AXUIElement, String)?
    var hops = 0
    while let c = cur, hops < 10 {
        for a in selectionAttrs {
            if let arr = elements(attr(c, a)) {
                if !arr.isEmpty { return (c, a, arr) }
                if firstEmpty == nil { firstEmpty = (c, a) }
            }
        }
        if role(c) == kAXWindowRole { break }
        cur = element(attr(c, kAXParentAttribute))
        hops += 1
    }
    if let (c, a) = firstEmpty { return (c, a, []) }
    return nil
}

// Запасной путь: обход окна вниз, если от фокуса выделение не нашлось.
func searchSelection(in window: AXUIElement) -> (AXUIElement, String, [AXUIElement])? {
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var visited = 0
    while !queue.isEmpty, visited < 400 {
        let (el, depth) = queue.removeFirst()
        visited += 1
        for a in selectionAttrs {
            if let arr = elements(attr(el, a)), !arr.isEmpty { return (el, a, arr) }
        }
        if depth < 7, let kids = elements(attr(el, kAXChildrenAttribute)) {
            queue.append(contentsOf: kids.map { ($0, depth + 1) })
        }
    }
    return nil
}

var registeredContainers: [AXUIElement] = []
var observer: AXObserver?

func registerSelectionNotifications(on el: AXUIElement) {
    guard let observer, !registeredContainers.contains(where: { CFEqual($0, el) }) else { return }
    registeredContainers.append(el)
    var results: [String] = []
    for n in [kAXSelectedRowsChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedCellsChangedNotification] {
        let e = AXObserverAddNotification(observer, el, n as CFString, nil)
        results.append("\(n)=\(axErr(e))")
    }
    log("   подписка на контейнер \(roleKey(el)): " + results.joined(separator: ", "))
}

func snapshot(reason: String) -> Snapshot {
    let t0 = now()
    guard let focused = element(attr(app, kAXFocusedUIElementAttribute)) else {
        let s = Snapshot(at: now(), focus: "нет", isText: false, source: "нет фокуса", items: [], totalMs: ms(since: t0))
        log("▶ снимок (\(reason)): у Finder нет сфокусированного элемента")
        return s
    }
    let focus = roleKey(focused)
    var settable = DarwinBoolean(false)
    AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
    let isText = textRoles.contains(role(focused)) && settable.boolValue

    let window = element(attr(focused, kAXWindowAttribute)) ?? element(attr(app, kAXFocusedWindowAttribute))
    let winTitle = window.flatMap { str($0, kAXTitleAttribute) } ?? "—"
    let winDoc = window.flatMap { str($0, kAXDocumentAttribute) } ?? "—"

    var source = "не найдено"
    var items: [Item] = []
    var container: AXUIElement?
    var found = findSelection(from: focused)
    var how = "от фокуса"
    if found == nil, let window {
        found = searchSelection(in: window)
        how = "обход окна"
    }
    if let (c, a, arr) = found {
        container = c
        source = "\(a) у \(roleKey(c)) (\(how))"
        items = arr.map(identify)
    }
    let total = ms(since: t0)
    record("Σ снимок целиком", total)

    let s = Snapshot(at: now(), focus: focus, isText: isText, source: source, items: items, totalMs: total)
    log("▶ снимок (\(reason)), \(String(format: "%.1f", total)) мс")
    log("   фокус: \(focus)\(isText ? " — ТЕКСТОВОЕ ПОЛЕ" : ""); окно: \"\(winTitle)\"; AXDocument: \(winDoc)")
    log("   выделение: \(source) → \(items.count) шт.")
    for it in items {
        let img = it.isImage.map { $0 ? "изображение" : "не изображение" } ?? "тип ?"
        log("     • \(it.name ?? "?")  [\(it.via)] \(img)")
    }

    dumpOnce(focused, label: "фокуса")
    if let container {
        dumpOnce(container, label: "контейнера")
        registerSelectionNotifications(on: container)
    }
    if let first = found?.2.first { dumpOnce(first, label: "элемента выделения") }
    return s
}

// MARK: - Apple Events (эталон)

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

@discardableResult
func appleScript(_ source: String, key: String) -> String? {
    var err: NSDictionary?
    let t0 = now()
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
    record(key, ms(since: t0))
    if let err {
        log("   ⚠️ AppleScript (\(key)): \(err[NSAppleScript.errorMessage] ?? err)")
        return nil
    }
    return result?.stringValue ?? ""
}

func finderSelectionAE() -> Set<String>? {
    let src = """
    tell application "Finder"
        set out to ""
        repeat with i in (get selection)
            set out to out & POSIX path of (i as alias) & linefeed
        end repeat
        return out
    end tell
    """
    guard let raw = appleScript(src, key: "AE: get selection") else { return nil }
    let names = raw.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }
    return Set(names)
}

func compareWithAE(_ s: Snapshot) {
    guard compareWithAppleEvents, let ae = finderSelectionAE() else { return }
    let verdict = ae == s.names ? "СОВПАДАЕТ" : "РАСХОДИТСЯ"
    log("   Apple Events: \(ae.sorted().joined(separator: ", ")) → \(verdict)")
}

// MARK: - Уведомления

var notifications: [(at: UInt64, name: String)] = []
var snapshotTimes: [UInt64] = []
var pendingSnapshot: DispatchWorkItem?
var notificationsSinceSnapshot = 0
var lastNotified: Snapshot?

func onNotification(_ el: AXUIElement, _ name: String) {
    notifications.append((now(), name))
    notificationsSinceSnapshot += 1
    pendingSnapshot?.cancel()
    let work = DispatchWorkItem {
        let n = notificationsSinceSnapshot
        notificationsSinceSnapshot = 0
        snapshotTimes.append(now())
        let s = snapshot(reason: "после \(n) уведомл., дебаунс \(Int(debounceMs)) мс; последнее: \(name)")
        lastNotified = s
        if mode == "watch" { compareWithAE(s) }
    }
    pendingSnapshot = work
    DispatchQueue.main.asyncAfter(deadline: .now() + debounceMs / 1000, execute: work)
}

func startObserving() {
    let callback: AXObserverCallback = { _, element, notification, _ in
        onNotification(element, notification as String)
    }
    var obs: AXObserver?
    let err = AXObserverCreate(finderPid, callback, &obs)
    guard err == .success, let obs else {
        log("AXObserverCreate: \(axErr(err))")
        exit(1)
    }
    observer = obs
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    var results: [String] = []
    for n in [kAXFocusedUIElementChangedNotification, kAXSelectedChildrenChangedNotification,
              kAXSelectedRowsChangedNotification, kAXSelectedCellsChangedNotification,
              kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
              kAXTitleChangedNotification] {
        let e = AXObserverAddNotification(obs, app, n as CFString, nil)
        results.append("\(n)=\(axErr(e))")
    }
    log("Подписка на приложение Finder (pid \(finderPid)):")
    for r in results { log("   \(r)") }
}

// MARK: - Тестовая папка

func writeImage(_ url: URL, _ type: UTType, size: Int, hue: CGFloat) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        log("   не удалось создать \(url.lastPathComponent) (\(type.identifier) не поддерживается)")
        return
    }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func generateTestData() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: testDataPath)
    let many = root.appendingPathComponent("many")
    try? fm.createDirectory(at: many, withIntermediateDirectories: true)
    try? fm.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
    writeImage(root.appendingPathComponent("photo-01.jpg"), .jpeg, size: 400, hue: 0.0)
    writeImage(root.appendingPathComponent("photo-02.png"), .png, size: 400, hue: 0.3)
    writeImage(root.appendingPathComponent("photo-10.heic"), .heic, size: 400, hue: 0.6)
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    if let pdf = CGContext(root.appendingPathComponent("doc.pdf") as CFURL, mediaBox: &box, nil) {
        pdf.beginPDFPage(nil)
        pdf.fill(box)
        pdf.endPDFPage()
        pdf.closePDF()
    }
    try? "Ementium test\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    for i in 1...150 {
        writeImage(many.appendingPathComponent(String(format: "img-%03d.png", i)), .png, size: 16, hue: CGFloat(i % 12) / 12)
    }
    log("Тестовая папка: \(root.path)")
}

// MARK: - Автосценарий

struct Result {
    let view: String
    let caseName: String
    let expected: Set<String>
    let notified: Snapshot?
    let direct: Snapshot
    let ae: Set<String>?
}

var results: [Result] = []
var burstReports: [String] = []

struct Step {
    let title: String
    let wait: Double
    let run: () -> Void
    let check: (() -> Void)?
}

var steps: [Step] = []
var stepStart: UInt64 = 0

func runStep(_ i: Int) {
    guard i < steps.count else { finishAuto(); return }
    let s = steps[i]
    log("")
    log("=== Шаг \(i + 1)/\(steps.count): \(s.title)")
    stepStart = now()
    s.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + s.wait) {
        s.check?()
        runStep(i + 1)
    }
}

func alias(_ path: String) -> String { "(POSIX file \"\(escape(path))\" as alias)" }

func checkCase(view: String, caseName: String, expected: Set<String>) {
    let notified = (lastNotified?.at ?? 0) > stepStart ? lastNotified : nil
    let direct = snapshot(reason: "прямое чтение для проверки")
    let ae = finderSelectionAE()
    results.append(Result(view: view, caseName: caseName, expected: expected, notified: notified, direct: direct, ae: ae))
    let mark = { (ok: Bool) in ok ? "✓" : "✗" }
    log("   итог: уведомление \(mark(notified?.names == expected)), прямое чтение \(mark(direct.names == expected)), Apple Events \(mark(ae == expected))")
}

func postKey(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
}

func buildAutoScenario() {
    let root = testDataPath
    let many = root + "/many"
    let views = [("icon view", "значки"), ("list view", "список"), ("column view", "колонки"), ("flow view", "галерея")]
    let cases: [(String, [String])] = [
        ("одно изображение", ["photo-01.jpg"]),
        ("PDF", ["doc.pdf"]),
        ("два изображения", ["photo-01.jpg", "photo-02.png"]),
        ("изображение + PDF", ["photo-02.png", "doc.pdf"]),
        ("HEIC", ["photo-10.heic"]),
        ("папка", ["folder"]),
    ]

    steps.append(Step(title: "открыть тестовую папку в новом окне Finder", wait: 2.0, run: {
        appleScript("""
        tell application "Finder"
            activate
            make new Finder window to \(alias(root))
        end tell
        """, key: "AE: сценарий")
    }, check: nil))

    for (view, viewName) in views {
        steps.append(Step(title: "режим «\(viewName)»", wait: 1.5, run: {
            appleScript("""
            tell application "Finder"
                activate
                set target of front window to \(alias(root))
                set current view of front window to \(view)
            end tell
            """, key: "AE: сценарий")
        }, check: nil))
        for (caseName, files) in cases {
            steps.append(Step(title: "\(viewName): \(caseName)", wait: 0.8, run: {
                let list = files.map { alias(root + "/" + $0) }.joined(separator: ", ")
                appleScript("tell application \"Finder\" to set selection to {\(list)}", key: "AE: сценарий")
            }, check: {
                checkCase(view: viewName, caseName: caseName, expected: Set(files))
            }))
        }
    }

    // Частота уведомлений: зажатая стрелка вниз в большой папке.
    for (view, viewName) in [("list view", "список"), ("icon view", "значки")] {
        let presses = 60
        let interval = 0.03
        var burstStart: UInt64 = 0
        steps.append(Step(title: "очередь стрелок, подготовка (\(viewName), папка many)", wait: 1.5, run: {
            appleScript("""
            tell application "Finder"
                activate
                set target of front window to \(alias(many))
                set current view of front window to \(view)
                set selection to {\(alias(many + "/img-001.png"))}
            end tell
            """, key: "AE: сценарий")
        }, check: nil))
        steps.append(Step(title: "\(presses) нажатий ↓ с интервалом \(Int(interval * 1000)) мс (\(viewName))",
                          wait: Double(presses) * interval + 1.5, run: {
            burstStart = now()
            for k in 0..<presses {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * interval) { postKey(125) }
            }
        }, check: {
            let ns = notifications.filter { $0.at >= burstStart }
            let snaps = snapshotTimes.filter { $0 >= burstStart }.count
            var byName: [String: Int] = [:]
            for n in ns { byName[n.name, default: 0] += 1 }
            let detail = byName.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            let direct = snapshot(reason: "прямое чтение после очереди")
            let ae = finderSelectionAE()
            let line = "\(viewName): \(presses) нажатий → \(ns.count) уведомл. (\(detail)), снимков после дебаунса: \(snaps); "
                + "итоговое выделение AX \(direct.names.sorted()) / AE \(ae?.sorted() ?? [])"
            burstReports.append(line)
            log("   " + line)
        }))
    }

    steps.append(Step(title: "закрыть тестовое окно", wait: 0.5, run: {
        appleScript("tell application \"Finder\" to close front window", key: "AE: сценарий")
    }, check: nil))
}

func finishAuto() {
    log("")
    log("===== РЕЗУЛЬТАТЫ АВТОСЦЕНАРИЯ =====")
    log("режим      | случай             | уведомл. | прямое | AE | откуда взято выделение / как определено имя")
    for r in results {
        let n = r.notified?.names == r.expected ? "✓" : (r.notified == nil ? "нет" : "✗")
        let d = r.direct.names == r.expected ? "✓" : "✗"
        let a = r.ae == r.expected ? "✓" : "✗"
        let via = r.direct.items.first?.via ?? "—"
        log(r.view.padding(toLength: 10, withPad: " ", startingAt: 0) + " | "
            + r.caseName.padding(toLength: 18, withPad: " ", startingAt: 0) + " | "
            + n.padding(toLength: 8, withPad: " ", startingAt: 0) + " | "
            + d.padding(toLength: 6, withPad: " ", startingAt: 0) + " | "
            + a.padding(toLength: 2, withPad: " ", startingAt: 0) + " | "
            + r.direct.source + " / " + via)
        if r.direct.names != r.expected {
            log("           ожидалось \(r.expected.sorted()), AX дал \(r.direct.names.sorted())")
        }
    }
    log("")
    for b in burstReports { log("Очередь стрелок — " + b) }
    printSummary()
    exit(0)
}

// MARK: - Итоговая статистика

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func printSummary() {
    log("")
    log("===== ВРЕМЯ ЗАПРОСОВ, мс =====")
    log("запрос                              кол-во   среднее   p50     p95     макс")
    for (key, s) in stats.sorted(by: { $0.value.samples.reduce(0, +) > $1.value.samples.reduce(0, +) }) {
        let v = s.samples.sorted()
        let avg = v.reduce(0, +) / Double(v.count)
        log(key.padding(toLength: 34, withPad: " ", startingAt: 0)
            + String(format: "  %6d  %7.2f  %6.2f  %6.2f  %7.2f", v.count, avg, percentile(v, 0.5), percentile(v, 0.95), v.last ?? 0))
    }
    log("")
    log("===== УВЕДОМЛЕНИЯ =====")
    var byName: [String: Int] = [:]
    for n in notifications { byName[n.name, default: 0] += 1 }
    for (k, v) in byName.sorted(by: { $0.value > $1.value }) { log("\(k): \(v)") }
    if notifications.count > 1 {
        let intervals = zip(notifications.dropFirst(), notifications).map { Double($0.0.at - $0.1.at) / 1e6 }.sorted()
        var maxPerSecond = 0
        var j = 0
        for i in notifications.indices {
            while notifications[i].at - notifications[j].at > 1_000_000_000 { j += 1 }
            maxPerSecond = max(maxPerSecond, i - j + 1)
        }
        log(String(format: "всего %d, снимков после дебаунса %d; интервал между уведомлениями: мин %.1f мс, медиана %.1f мс; пик %d в секунду",
                   notifications.count, snapshotTimes.count, intervals.first ?? 0, percentile(intervals, 0.5), maxPerSecond))
    } else {
        log("уведомлений: \(notifications.count)")
    }
}

// MARK: - Запуск

if mode == "gen" {
    generateTestData()
    exit(0)
}

guard mode == "watch" || mode == "auto" else {
    print("Режим: watch | auto | gen")
    exit(2)
}

let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
guard trusted else {
    print("""
    Нет доступа Accessibility.
    Системные настройки → Конфиденциальность и безопасность → Универсальный доступ →
    включи приложение терминала, из которого запускаешь (Terminal), и перезапусти его.
    """)
    exit(1)
}

log("FinderAXProbe: режим \(mode), дебаунс \(Int(debounceMs)) мс, сравнение с Apple Events: \(compareWithAppleEvents ? "да" : "нет")")
log("Finder: \(finder.bundleURL?.path ?? "?"), версия \(Bundle(url: finder.bundleURL!)?.infoDictionary?["CFBundleShortVersionString"] ?? "?"); macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
startObserving()

let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
sigint.setEventHandler {
    printSummary()
    exit(0)
}
sigint.resume()

if mode == "auto" {
    generateTestData()
    buildAutoScenario()
    log("Автосценарий: \(steps.count) шагов. Не трогай мышь и клавиатуру, пока он идёт.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { runStep(0) }
} else {
    log("""
    Кликай в Finder — каждое изменение попадёт в лог. Что проверить:
      • режимы: значки, список, колонки, галерея (⌘1…⌘4), по одному файлу, по несколько, картинка + PDF;
      • рабочий стол, окно поиска (⌘F), «Недавние», iCloud Drive, сетевой диск;
      • текстовые поля: переименование (Return), строка поиска, «Переход к папке» (⇧⌘G);
      • зажатую стрелку в большой папке.
    Ctrl+C — итоговая статистика.
    """)
    _ = snapshot(reason: "начальное состояние")
}

RunLoop.main.run()
