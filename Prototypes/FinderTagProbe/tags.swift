// FinderTagProbe — как ставить цветные теги Finder из стороннего процесса на macOS 27 (v1.4, метки клавишами 1–7).
//
//   tags auto                  — запись и чтение, имена цветов, ошибки, дата изменения (testdata/auto)
//   tags labels                — цветные метки системы: имена, порядок, цвета
//   tags setup                 — папка testdata/finder с картинками для проверки в Finder
//   tags toggle <файл> <1…7>   — переключить метку (порядок меню Finder) и показать теги файла
//   tags show <файл>           — теги файла: API, сырой атрибут, даты
import AppKit
import Darwin

let start = Date()
func log(_ text: String) {
    print(String(format: "[%6.3f] ", Date().timeIntervalSince(start)) + text)
    fflush(stdout)
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let testdata = root.appendingPathComponent("testdata")

// MARK: - Теги: API и сырой атрибут

func tagNames(_ url: URL) throws -> [String] {
    // Кэш URL не должен отдавать прежние теги — свежий URL на каждый запрос.
    let fresh = URL(fileURLWithPath: url.path)
    return try fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
}

func setTagNames(_ url: URL, _ names: [String]) throws {
    try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(names as NSArray, forKey: .tagNamesKey)
}

/// `com.apple.metadata:_kMDItemUserTags` — список «имя\nцвет», как его хранит система.
func rawUserTags(_ url: URL) -> String {
    let name = "com.apple.metadata:_kMDItemUserTags"
    let size = getxattr(url.path, name, nil, 0, 0, 0)
    guard size > 0 else { return size == 0 ? "[] (пусто)" : "нет атрибута" }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
    guard read == size, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    else { return "не разобрать" }
    return "[" + list.map { $0.replacingOccurrences(of: "\n", with: "⏎") }.joined(separator: ", ") + "]"
}

/// Цвет метки в `com.apple.FinderInfo` (старые «ярлыки»: биты 1–3 байта 9).
func finderInfoLabel(_ url: URL) -> String {
    var info = [UInt8](repeating: 0, count: 32)
    let read = getxattr(url.path, "com.apple.FinderInfo", &info, 32, 0, 0)
    guard read == 32 else { return "нет FinderInfo" }
    return "ярлык \((info[9] >> 1) & 7)"
}

struct Dates: Equatable {
    var modified: timespec
    var changed: timespec
    static func == (a: Dates, b: Dates) -> Bool {
        a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
            && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
}

func dates(_ url: URL) -> Dates {
    var info = stat()
    stat(url.path, &info)
    return Dates(modified: info.st_mtimespec, changed: info.st_ctimespec)
}

func describe(_ url: URL) -> String {
    let api = (try? tagNames(url)).map { "[" + $0.joined(separator: ", ") + "]" } ?? "ошибка чтения"
    return "API \(api); атрибут \(rawUserTags(url)); \(finderInfoLabel(url))"
}

func describeError(_ error: Error) -> String {
    let ns = error as NSError
    var text = "\(ns.domain) \(ns.code) «\(ns.localizedDescription)»"
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
        text += " ← \(underlying.domain) \(underlying.code)"
    }
    return text
}

// MARK: - Цветные метки системы

/// Номера старых ярлыков (`NSWorkspace.fileLabels`) в порядке меню Finder: красный, оранжевый, жёлтый, зелёный,
/// синий, лиловый, серый. Порядок `fileLabels` другой — его и проверяет `labels`.
let menuOrderLabelIndices = [6, 7, 5, 2, 4, 3, 1]

func colorTagNames() -> [String] {
    let labels = NSWorkspace.shared.fileLabels
    return menuOrderLabelIndices.map { $0 < labels.count ? labels[$0] : "?" }
}

func printLabels() {
    let labels = NSWorkspace.shared.fileLabels
    let colors = NSWorkspace.shared.fileLabelColors
    log("Язык системы: \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))")
    log("NSWorkspace.fileLabels (\(labels.count)), по номеру ярлыка:")
    for (index, name) in labels.enumerated() {
        let color = index < colors.count ? colors[index].usingColorSpace(.sRGB).map {
            String(format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255))
        } ?? "?" : "?"
        log("  \(index): «\(name)» \(color)")
    }
    log("В порядке меню Finder: \(colorTagNames().joined(separator: ", "))")
}

/// Имена цветных тегов на языке системы, в порядке меню Finder (`nil` — имени не нашлось). Кандидаты — избранные
/// теги Finder (`FavoriteTagNames`, язык системы) и `fileLabels` (язык программы); цвет каждому даёт сама система —
/// запись во временный файл и номер цвета из атрибута. Регистр и «ё» система не различает.
func resolvedColorNames() -> [String?] {
    let dir = testdata.appendingPathComponent("auto")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let favorites = UserDefaults(suiteName: "com.apple.finder")?.stringArray(forKey: "FavoriteTagNames") ?? []
    let candidates = (favorites + NSWorkspace.shared.fileLabels).filter { !$0.isEmpty }
    let probe = fresh("resolve.png", in: dir)
    defer { try? FileManager.default.removeItem(at: probe) }
    var byColor: [Int: String] = [:]
    for name in candidates {
        guard (try? setTagNames(probe, [name])) != nil else { continue }
        if let color = rawUserTags(probe).split(separator: "⏎").last.flatMap({ Int($0.dropLast()) }), color > 0,
           byColor[color] == nil {
            byColor[color] = name
        }
    }
    return menuOrderLabelIndices.map { byColor[$0] }
}

// MARK: - auto

func makeImage(_ url: URL, hue: CGFloat) {
    let size = NSSize(width: 64, height: 64)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

func fresh(_ name: String, in dir: URL) -> URL {
    let url = dir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    makeImage(url, hue: 0.3)
    return url
}

func run(_ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

func auto() {
    let dir = testdata.appendingPathComponent("auto")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let colors = colorTagNames()
    printLabels()

    log("== 1. Запись через tagNamesKey, чужие теги")
    let a = fresh("a.png", in: dir)
    do {
        try setTagNames(a, ["Работа"])
        log("  поставил свой тег «Работа»: \(describe(a))")
        let added = try tagNames(a) + [colors[0]]
        try setTagNames(a, added)
        log("  добавил «\(colors[0])» к прочитанному: \(describe(a))")
        try setTagNames(a, try tagNames(a).filter { $0 != colors[0] })
        log("  снял «\(colors[0])»: \(describe(a))")
    } catch { log("  ошибка: \(describeError(error))") }

    log("== 2. Какие имена дают цветной тег")
    let candidates = colors + ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray", "Красный", "красный", "RED"]
    for name in candidates {
        let url = fresh("c.png", in: dir)
        do {
            try setTagNames(url, [name])
            log("  «\(name)» → \(describe(url))")
        } catch { log("  «\(name)»: ошибка \(describeError(error))") }
    }
    let both = fresh("d.png", in: dir)
    do {
        try setTagNames(both, [colors[0], colors[4]])
        log("  два цвета сразу → \(describe(both))")
    } catch { log("  два цвета: ошибка \(describeError(error))") }

    log("== 7. Дата изменения")
    let m = fresh("m.png", in: dir)
    Thread.sleep(forTimeInterval: 1.1)
    let before = dates(m)
    do {
        try setTagNames(m, [colors[1]])
        let after = dates(m)
        log("  mtime: \(before.modified.tv_sec).\(before.modified.tv_nsec) → \(after.modified.tv_sec).\(after.modified.tv_nsec) — \(before.modified.tv_sec == after.modified.tv_sec && before.modified.tv_nsec == after.modified.tv_nsec ? "НЕ изменилась" : "ИЗМЕНИЛАСЬ")")
        log("  ctime (изменение атрибутов): \(before.changed.tv_sec) → \(after.changed.tv_sec)")
        let created = (try? FileManager.default.attributesOfItem(atPath: m.path)[.creationDate]) as? Date
        log("  дата создания после записи: \(created.map { "\($0)" } ?? "?")")
    } catch { log("  ошибка: \(describeError(error))") }

    log("== 5. Ошибки")
    // Права только на чтение у владельца.
    let readOnly = fresh("readonly.png", in: dir)
    chmod(readOnly.path, 0o444)
    do { try setTagNames(readOnly, [colors[2]]); log("  файл 0444: записалось → \(describe(readOnly))") }
    catch { log("  файл 0444: \(describeError(error))") }
    chmod(readOnly.path, 0o644)
    // Защищённый (флаг uchg, «Защита» в «Свойствах» Finder).
    let locked = fresh("locked.png", in: dir)
    chflags(locked.path, UInt32(UF_IMMUTABLE))
    do { try setTagNames(locked, [colors[2]]); log("  защищённый (uchg): записалось → \(describe(locked))") }
    catch { log("  защищённый (uchg): \(describeError(error))") }
    chflags(locked.path, 0)
    // Файла нет.
    do { try setTagNames(dir.appendingPathComponent("нет.png"), [colors[2]]); log("  несуществующий: записалось?!") }
    catch { log("  несуществующий: \(describeError(error))") }
    // Том только для чтения: образ с файлом, подключённый -readonly.
    let image = dir.appendingPathComponent("ro.dmg")
    let mount = dir.appendingPathComponent("ro-mount")
    try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let source = dir.appendingPathComponent("ro-source")
    try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    makeImage(source.appendingPathComponent("r.png"), hue: 0.6)
    let created = run(["/usr/bin/hdiutil", "create", "-quiet", "-srcfolder", source.path, "-format", "UDRO", "-fs", "APFS", image.path])
    if created.0 == 0 {
        let attached = run(["/usr/bin/hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path])
        if attached.0 == 0 {
            let file = mount.appendingPathComponent("r.png")
            do { try setTagNames(file, [colors[2]]); log("  том только для чтения: записалось?! → \(describe(file))") }
            catch { log("  том только для чтения: \(describeError(error))") }
            let readable = (try? tagNames(file)).map { "читается: \($0)" } ?? "не читается"
            log("  том только для чтения, чтение тегов: \(readable)")
            _ = run(["/usr/bin/hdiutil", "detach", "-quiet", mount.path])
        } else { log("  том только для чтения: не подключился — \(attached.1)") }
    } else { log("  том только для чтения: образ не создан — \(created.1)") }
    let smb = run(["/sbin/mount"]).1.split(separator: "\n").filter { $0.contains("smbfs") }.count
    log("  SMB-томов подключено: \(smb) (проверка — вручную, если есть)")
    log("Готово")
}

// MARK: - setup / toggle / show

func setup() {
    let dir = testdata.appendingPathComponent("finder")
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for index in 1...12 {
        makeImage(dir.appendingPathComponent(String(format: "photo-%02d.png", index)), hue: CGFloat(index) / 13)
    }
    try? "Документ между картинками\n".write(to: dir.appendingPathComponent("photo-06a.txt"), atomically: true, encoding: .utf8)
    // Пара картинок с метками заранее — чтобы группировка по тегам сразу была видна.
    let colors = resolvedColorNames().map { $0 ?? "?" }
    try? setTagNames(dir.appendingPathComponent("photo-03.png"), [colors[0]])
    try? setTagNames(dir.appendingPathComponent("photo-09.png"), [colors[4]])
    log("Папка: \(dir.path)")
    NSWorkspace.shared.open(dir)
}

func toggle(_ path: String, _ number: Int) {
    let url = URL(fileURLWithPath: path)
    let colors = resolvedColorNames().map { $0 ?? "?" }
    guard (1...7).contains(number) else { log("номер метки 1…7"); exit(1) }
    let tag = colors[number - 1]
    do {
        let before = try tagNames(url)
        let has = before.contains { $0.compare(tag, options: .caseInsensitive) == .orderedSame }
        let after = has ? before.filter { $0.compare(tag, options: .caseInsensitive) != .orderedSame } : before + [tag]
        let started = Date()
        try setTagNames(url, after)
        log("\(has ? "снял" : "поставил") «\(tag)» за \(Int(Date().timeIntervalSince(started) * 1000)) мс → \(describe(url))")
    } catch { log("ошибка: \(describeError(error))") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "auto": auto()
case "labels": printLabels()
case "resolve":
    let started = Date()
    let names = resolvedColorNames()
    log("проверка \(Int(Date().timeIntervalSince(started) * 1000)) мс")
    log("1–7: " + names.map { $0 ?? "— (нет имени)" }.joined(separator: ", "))
case "labelnumber":
    // Старый ярлык по номеру цвета: какое имя тега получится и что будет со вторым ярлыком и с чужим тегом.
    let dir = testdata.appendingPathComponent("auto")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for number in [6, 7, 5, 2, 4, 3, 1] {
        let url = fresh("l.png", in: dir)
        do {
            try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(number, forKey: .labelNumberKey)
            log("ярлык \(number) → \(describe(url))")
        } catch { log("ярлык \(number): \(describeError(error))") }
    }
    let url = fresh("l2.png", in: dir)
    do {
        try setTagNames(url, ["Работа"])
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(6, forKey: .labelNumberKey)
        log("«Работа» + ярлык 6 → \(describe(url))")
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(4, forKey: .labelNumberKey)
        log("затем ярлык 4 → \(describe(url))")
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(0, forKey: .labelNumberKey)
        log("затем ярлык 0 → \(describe(url))")
    } catch { log("ошибка: \(describeError(error))") }
case "color" where args.count > 1:
    // Какой цвет система даёт имени: запись в пустой файл, номер цвета из атрибута.
    let dir = testdata.appendingPathComponent("auto")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in args.dropFirst() {
        let url = fresh("n.png", in: dir)
        do { try setTagNames(url, [name]); log("«\(name)» → \(rawUserTags(url))") }
        catch { log("«\(name)»: \(describeError(error))") }
    }
case "setup": setup()
case "toggle" where args.count == 3: toggle(args[1], Int(args[2]) ?? 0)
case "show" where args.count == 2:
    let url = URL(fileURLWithPath: args[1])
    let d = dates(url)
    log("\(describe(url)); mtime \(d.modified.tv_sec), ctime \(d.changed.tv_sec)")
default:
    print("tags auto | labels | setup | toggle <файл> <1…7> | show <файл>")
    exit(1)
}
