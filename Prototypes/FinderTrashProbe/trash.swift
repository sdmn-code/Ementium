// FinderTrashProbe — как Finder ведёт себя, если послать ему ⌘⌫ и ⌘Z (как будет делать Ementium в режиме
// «следовать»): куда уходит выделение после удаления в каждом виде, исчезает ли файл, за сколько;
// возвращает ли ⌘Z файл и выделяет ли его.
//
// Работает только со своей тестовой папкой testdata/trash (создаётся заново перед каждым случаем).
// Удалённые и не вернувшиеся файлы остаются в Корзине — это сгенерированные пустышки.
//
// Одноразовый исследовательский код, в приложение не переносится.

import AppKit
import ApplicationServices

// MARK: - Лог

let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("testdata/trash").path
var logPath: String?
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if let index = args.firstIndex(of: "--log"), index + 1 < args.count { logPath = args[index + 1] }
}
let start = DispatchTime.now().uptimeNanoseconds
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ from: UInt64) -> Int { Int(Double(now() - from) / 1e6) }
var logHandle: FileHandle?
if let logPath {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    logHandle = FileHandle(forWritingAtPath: logPath)
}
func log(_ s: String) {
    let line = String(format: "[%7.2f] ", Double(now() - start) / 1e9) + s
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

/// Имена выделенных файлов («—», если выделения нет).
func selection() -> String {
    guard let focused = element(attr(axFinder, kAXFocusedUIElementAttribute)) else { return "нет фокуса" }
    let items = elements(attr(focused, kAXSelectedRowsAttribute)) ?? elements(attr(focused, kAXSelectedChildrenAttribute)) ?? []
    let names = items.compactMap { findURL($0, 2)?.lastPathComponent }
    return names.isEmpty ? "—" : names.joined(separator: ", ")
}

func viewName() -> String {
    guard let focused = element(attr(axFinder, kAXFocusedUIElementAttribute)) else { return "?" }
    switch attr(focused, kAXIdentifierAttribute) as? String {
    case "ListView": return "список"
    case "IconView": return "значки"
    case "GalleryView": return "галерея"
    default: return (attr(focused, kAXRoleAttribute) as? String) == kAXListRole ? "колонки" : "?"
    }
}

/// Выделить файл `name` в текущем виде через AX (значки, галерея — коллекция; список, колонки — строки).
func selectViaAX(_ name: String) -> Bool {
    guard let focused = element(attr(axFinder, kAXFocusedUIElementAttribute)) else { return false }
    var candidates: [AXUIElement] = []
    if let rows = elements(attr(focused, kAXRowsAttribute)) {
        candidates = rows
    } else {
        let children = elements(attr(focused, kAXChildrenAttribute)) ?? []
        let sections = children.filter { attr($0, kAXRoleAttribute) as? String == kAXListRole }
        candidates = sections.isEmpty ? children : sections.flatMap { elements(attr($0, kAXChildrenAttribute)) ?? [] }
    }
    guard let item = candidates.first(where: { findURL($0, 2)?.lastPathComponent == name }) else { return false }
    let key = elements(attr(focused, kAXRowsAttribute)) != nil ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute
    return AXUIElementSetAttributeValue(focused, key as CFString, [item] as CFArray) == .success
}

// MARK: - Клавиши Finder, как в Ementium (напрямую процессу)

func postToFinder(keyCode: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
        event.flags = flags
        event.postToPid(finderPID)
    }
}
func commandDelete() { postToFinder(keyCode: 51, flags: .maskCommand) }
func commandZ() { postToFinder(keyCode: 6, flags: .maskCommand) }

/// Ждёт, пока выделение станет не `before` (или пройдёт `timeout` мс). Возвращает выделение и время.
func waitForSelectionChange(from before: String, timeout: Int = 1500) -> (String, Int) {
    let t0 = now()
    var current = selection()
    while current == before, ms(t0) < timeout {
        usleep(20_000)
        current = selection()
    }
    // Дать Finder дособрать выделение (в колонках оно бывает пустым промежуточно).
    usleep(150_000)
    return (selection(), ms(t0))
}

// MARK: - AppleScript (только на главном потоке)

/// С таймаутом: без него NSAppleScript ждёт ответа Finder до 2 минут (так прототип «завис» в галерее).
@discardableResult
func appleScript(_ source: String) -> Bool {
    var ok = false
    let t0 = now()
    DispatchQueue.main.sync {
        var error: NSDictionary?
        NSAppleScript(source: "with timeout of 10 seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
        if let error { log("   ⚠️ AppleScript: \(error[NSAppleScript.errorMessage] ?? error)") } else { ok = true }
    }
    if ms(t0) > 3000 { log("   ⏱ AppleScript шёл \(ms(t0)) мс: \(source.prefix(80))") }
    return ok
}
func quoted(_ path: String) -> String { "(POSIX file \"\(path)\" as alias)" }

// MARK: - Тестовая папка

/// Картинки и документы вперемешку: в конце — картинка, перед ней документ.
let layout = ["01.png", "02.png", "03.txt", "04.png", "05.txt", "06.txt", "07.png", "08.txt", "09.png"]

func pngData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

/// Папку не пересоздаём (её окно открыто в Finder) — только файлы в ней.
func recreateFiles() {
    let fm = FileManager.default
    try! fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] { try? fm.removeItem(atPath: folder + "/" + name) }
    let png = pngData()
    for name in layout {
        let path = folder + "/" + name
        if name.hasSuffix(".png") { fm.createFile(atPath: path, contents: png) } else { fm.createFile(atPath: path, contents: Data("doc".utf8)) }
    }
}

func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder + "/" + name) }

// MARK: - Сценарий

struct Case {
    let title: String
    let targets: [String]  // два — удалить подряд быстро
}

let cases = [
    Case(title: "середина, дальше картинка", targets: ["01.png"]),
    Case(title: "перед документом", targets: ["04.png"]),
    Case(title: "между документами", targets: ["07.png"]),
    Case(title: "последний файл", targets: ["09.png"]),
    Case(title: "две подряд быстро", targets: ["01.png", "02.png"]),
]

var summary: [String] = []

func run(view asView: String, title: String) {
    log("")
    log("=== Вид «\(title)»")
    for test in cases {
        recreateFiles()
        // Своё окно — первое; окна Саши не трогаем.
        appleScript("""
        tell application "Finder"
            activate
            set target of front window to \(quoted(folder))
            set current view of front window to list view
            set sort column of list view options of front window to name column
        end tell
        """)
        usleep(1_200_000)
        if asView == "icon view" {
            appleScript("""
            tell application "Finder"
                set current view of front window to icon view
                set arrangement of icon view options of front window to arranged by name
            end tell
            """)
            usleep(300_000)
            appleScript("tell application \"Finder\" to set current view of front window to list view")
            usleep(300_000)
        }
        // Выделяем в «списке» — в «колонках» AppleScript выделение не ставит, а при смене вида оно сохраняется.
        appleScript("tell application \"Finder\" to set selection to {\(quoted(folder + "/" + test.targets[0]))}")
        usleep(300_000)
        if asView == "list view" {
            // После открытия окна фокус бывает в боковой панели; смена вида переносит его в список файлов.
            appleScript("tell application \"Finder\" to set current view of front window to icon view")
            usleep(400_000)
        }
        appleScript("tell application \"Finder\" to set current view of front window to \(asView)")
        usleep(900_000)

        let view = viewName()
        var before = selection()
        log(" • \(test.title): вид \(view), выделено \(before)")
        if before != test.targets[0] {
            log("   ⚠️ выделение не то — пропускаю")
            summary.append("\(title) | \(test.title) | выделение не поставилось")
            continue
        }

        var afterDelete = ""
        var deleteTime = 0
        var deleted: [String] = []
        for (index, target) in test.targets.enumerated() {
            if index > 0 {
                // Второе удаление сразу по выделению, которое Finder поставил после первого.
                // ⌘⌫ — только по тестовому файлу: что-то другое выделено — не удаляем.
                guard selection() == target else {
                    log("   после первого удаления выделено \(selection()), а не \(target) — второе не шлю")
                    break
                }
            }
            let t0 = now()
            commandDelete()
            let (after, elapsed) = waitForSelectionChange(from: before)
            // Файл мог исчезнуть позже смены выделения.
            var gone = !exists(target)
            while !gone, ms(t0) < 2000 { usleep(20_000); gone = !exists(target) }
            log("   ⌘⌫ \(target): выделение → \(after) за \(elapsed) мс; файл \(gone ? "в Корзине" : "НА МЕСТЕ") (\(ms(t0)) мс)")
            if after == "—", gone, let next = layout.drop(while: { $0 != target }).dropFirst().first ?? layout.last(where: { $0 != target }) {
                let t1 = now()
                let ok = selectViaAX(next)
                usleep(150_000)
                log("   выделение пустое → ставлю через AX \(next): \(ok ? "принято" : "ОТКАЗ"), выделено \(selection()) (\(ms(t1)) мс)")
            }
            afterDelete = after
            deleteTime = elapsed
            // ⌘Z — только за то, что точно удалили мы: лишний отменил бы чужое действие в Finder.
            if gone { deleted.append(target) }
            before = after
        }

        // Отмена: столько ⌘Z, сколько удалили.
        var undoReport: [String] = []
        for target in deleted.reversed() {
            let t0 = now()
            let beforeUndo = selection()
            commandZ()
            var back = exists(target)
            while !back, ms(t0) < 2500 { usleep(20_000); back = exists(target) }
            let (after, _) = waitForSelectionChange(from: beforeUndo, timeout: 1000)
            log("   ⌘Z: файл \(target) \(back ? "вернулся" : "НЕ вернулся") за \(ms(t0)) мс; выделение → \(after)")
            undoReport.append("\(target) \(back ? "вернулся" : "нет"), выделено \(after)")
        }
        summary.append("\(title) | \(test.title) | ⌘⌫ → \(afterDelete) (\(deleteTime) мс) | ⌘Z → \(undoReport.joined(separator: "; "))")
    }
}

DispatchQueue.global().async {
    recreateFiles()
    appleScript("tell application \"Finder\" to make new Finder window to \(quoted(folder))")
    usleep(800_000)
    log("FinderTrashProbe: папка \(folder)")
    log("Не трогай мышь и клавиатуру ~2 минуты. Finder будет издавать звук Корзины.")
    let views = [("list view", "список"), ("column view", "колонки"), ("icon view", "значки"), ("flow view", "галерея")]
    for (asView, title) in views { run(view: asView, title: title) }
    appleScript("tell application \"Finder\" to close front window")
    log("")
    log("=== Итог: вид | случай | после ⌘⌫ | после ⌘Z")
    for line in summary { log(line) }
    exit(0)
}
dispatchMain()
