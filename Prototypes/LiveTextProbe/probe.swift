// LiveTextProbe — как VisionKit (Live Text, «Поиск по изображению») и «Поделиться» ведут себя в панели,
// устроенной как окно просмотра Ementium: неактивирующая, уровень .screenSaver, картинка — CALayer с IOSurface.
//
//   probe measure [файлы…]        — время распознавания: экранная версия и полное разрешение, найденный текст
//   probe align [файл]            — скриншоты подсветки текста при масштабе и повороте (окно 1200×800 на 3 с)
//   probe overlay [файл] [--follow] — интерактивно, на весь экран; --follow: панель не берёт клавиатуру
//   probe sharetest [файл]        — меню «Поделиться» в панели .screenSaver и .statusBar: какие окна и на каком уровне
//
// Без файла — сгенерированная картинка с русским и английским текстом, телефоном, ссылкой и датой.
import AppKit
import CoreVideo
import ImageIO
import IOSurface
import VisionKit

let start = Date()
func log(_ text: String) {
    print(String(format: "[%7.3f] ", Date().timeIntervalSince(start)) + text)
    fflush(stdout)
}

// MARK: - Картинки

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let bgra = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

func testImage() -> CGImage {
    let width = 3000, height = 2000
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: bgra)!
    context.setFillColor(CGColor(gray: 0.96, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    let lines: [(String, CGFloat)] = [
        ("Ementium Live Text — проверка распознавания", 110),
        ("Телефон: +7 495 123-45-67", 90),
        ("https://github.com/sdmn-code/Ementium", 90),
        ("16 октября 2026 года, 15:30", 90),
        ("The quick brown fox jumps over the lazy dog", 80),
        ("Мелкий текст: съешь же ещё этих мягких французских булок, да выпей чаю", 30),
        ("Small text: pack my box with five dozen liquor jugs", 30),
    ]
    var y = CGFloat(height) - 240
    for (text, size) in lines {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 160, y: y))
        y -= size * 2.2
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    let side = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: side,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func scaled(_ image: CGImage, maxSide: Int) -> CGImage {
    let factor = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
    guard factor < 1 else { return image }
    let width = Int(CGFloat(image.width) * factor), height = Int(CGFloat(image.height) * factor)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: sRGB, bitmapInfo: bgra)!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Как `SurfaceConverter` приложения: BGRA, премультиплицированная альфа.
func surface(from image: CGImage) -> IOSurface {
    let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, image.width * 4)
    let surface = IOSurface(properties: [
        .width: image.width, .height: image.height, .bytesPerElement: 4, .bytesPerRow: bytesPerRow,
        .pixelFormat: 0x4247_5241,
    ])!
    surface.lock(options: [], seed: nil)
    let context = CGContext(data: surface.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: surface.bytesPerRow, space: sRGB, bitmapInfo: bgra)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    surface.unlock(options: [], seed: nil)
    return surface
}

func pixelBuffer(_ surface: IOSurface) -> CVPixelBuffer {
    var buffer: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(nil, surface as IOSurfaceRef, nil, &buffer)
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreateWithIOSurface: \(status)")
    return buffer!.takeRetainedValue()
}

func orientation(quarterTurns: Int) -> CGImagePropertyOrientation {
    [.up, .right, .down, .left][((quarterTurns % 4) + 4) % 4]
}

let analyzer = ImageAnalyzer()
let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])

@MainActor func analyze(_ surface: IOSurface, quarterTurns: Int = 0) async -> ImageAnalysis? {
    let started = Date()
    do {
        let analysis = try await analyzer.analyze(pixelBuffer(surface), orientation: orientation(quarterTurns: quarterTurns),
                                                  configuration: configuration)
        log(String(format: "анализ %dx%d за %.0f мс: текст=%@ lookUp=%@ коды=%@", surface.width, surface.height,
                   Date().timeIntervalSince(started) * 1000,
                   "\(analysis.hasResults(for: .text))", "\(analysis.hasResults(for: .visualLookUp))",
                   "\(analysis.hasResults(for: .machineReadableCode))"))
        return analysis
    } catch {
        log("анализ не удался: \(error)")
        return nil
    }
}

func images(_ paths: [String]) -> [(String, CGImage)] {
    paths.isEmpty ? [("test", testImage())] : paths.compactMap { path in loadImage(path).map { ((path as NSString).lastPathComponent, $0) } }
}

/// Файл для «Поделиться»: свой — как есть, сгенерированная — во временный PNG.
func fileURL(_ paths: [String], _ image: CGImage) -> URL {
    if let path = paths.first { return URL(fileURLWithPath: path) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTextProbe.png")
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    return url
}

// MARK: - measure

@MainActor func measure(_ paths: [String]) async {
    log("ImageAnalyzer.isSupported = \(ImageAnalyzer.isSupported)")
    log("языки текста: \(ImageAnalyzer.supportedTextRecognitionLanguages.joined(separator: ", "))")
    for (name, image) in images(paths) {
        log("== \(name): \(image.width)x\(image.height)")
        for (label, variant) in [("экранная (2560)", scaled(image, maxSide: 2560)), ("полная", image)] {
            log("-- \(label)")
            for run in 1...2 {
                guard let analysis = await analyze(surface(from: variant)) else { continue }
                if run == 1 {
                    log("текст: " + analysis.transcript.replacingOccurrences(of: "\n", with: " | ").prefix(400))
                }
            }
        }
    }
}

// MARK: - Окно как у просмотра

final class ProbePanel: NSPanel {
    var takesKeyboard = true
    override var canBecomeKey: Bool { takesKeyboard }
    /// KEYTRICK=pretend: сказаться ключевой, не забирая клавиатуру.
    var pretendKey = false
    override var isKeyWindow: Bool { pretendKey || super.isKeyWindow }
    static var traceEvents = false
    override func sendEvent(_ event: NSEvent) {
        if Self.traceEvents, [.leftMouseDown, .leftMouseUp].contains(event.type) {
            log("  панель sendEvent: \(event.type == .leftMouseDown ? "down" : "up") №\(event.eventNumber)")
        }
        super.sendEvent(event)
    }
}

/// Окна на экране выше обычного уровня: наши — все, чужие — только с уровнем ≥ 100 (меню и выше).
func listWindows(_ title: String) {
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var lines: [String] = []
    for w in list {
        let owner = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let name = w[kCGWindowOwnerName as String] as? String ?? ""
        let service = ["Messages", "Сообщения", "Share", "AirDrop", "Photos", "Фото", "View Service", "sharingd"].contains { name.contains($0) }
        guard owner == pid || layer > 0 || service else { continue }
        if name == "Window Server" || name == "Dock" || name == "Control Center" || name == "SystemUIServer" { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        lines.append("    \(w[kCGWindowOwnerName as String] ?? "?") pid=\(owner) уровень=\(layer) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) @\(b["X"] ?? 0),\(b["Y"] ?? 0)")
    }
    log("окна (\(title)), сверху вниз:\n" + lines.joined(separator: "\n"))
}

final class StageView: NSView, ImageAnalysisOverlayViewDelegate, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    let imageLayer = CALayer()
    let overlay = ImageAnalysisOverlayView()
    var imageSize = CGSize(width: 1, height: 1)
    var zoom: CGFloat = 1
    var offset = CGPoint.zero
    var quarterTurns = 0
    /// Режим ⌘: VisionKit отвечает на мышь и показывает кнопки.
    /// Взаимодействия VisionKit включены всегда (иначе отпускание ⌘ сбрасывает выделение), а начать новое
    /// можно только в режиме — `shouldBeginAt`. Вне режима мышь должна проходить к картинке (сдвиг).
    var isLiveMode = false {
        didSet {
            overlay.preferredInteractionTypes = .automatic
            overlay.setSupplementaryInterfaceHidden(!isLiveMode, animated: true)
            shareButton.isHidden = !isLiveMode
            // Кнопки VisionKit появляются с анимацией — положение читать после неё.
            if isLiveMode {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.placeShareButton() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.placeShareButton() }
            }
            log("режим ⌘: \(isLiveMode ? "вкл" : "выкл") (выделено: «\(overlay.selectedText.prefix(60))»)")
        }
    }

    // Сдвиг перетаскиванием — как в просмотре: проверяем, доходит ли мышь сквозь оверлей вне режима.
    var dragFrom: CGPoint?

    override func mouseDown(with event: NSEvent) {
        log("mouseDown у картинки (режим \(isLiveMode)) — сквозь оверлей прошло; выделение сброшено")
        overlay.resetSelection()
        dragFrom = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let from = dragFrom else { return }
        offset.x += event.locationInWindow.x - from.x
        offset.y += event.locationInWindow.y - from.y
        dragFrom = event.locationInWindow
        relayout()
    }
    let shareButton = NSButton()
    var shareURL: URL?
    let flipUnitY = ProcessInfo.processInfo.environment["UNIT_Y_UP"] == nil
    /// Оверлей ровно на картинке (масштабируется с ней), contentsRect — вся единичная площадь: проверено align,
    /// совпадает при масштабе и повороте. OVERLAY=view — оверлей на весь вид (при увеличении съезжает).
    let overlayOnImage = ProcessInfo.processInfo.environment["OVERLAY"] != "view"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        layer?.addSublayer(imageLayer)
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.delegate = self
        overlay.preferredInteractionTypes = []
        overlay.isSupplementaryInterfaceHidden = true
        addSubview(overlay)
        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareButton.bezelStyle = .glass
        shareButton.borderShape = .circle
        overlay.supplementaryInterfaceContentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 8 + 26 + 8)
        shareButton.isHidden = true
        shareButton.target = self
        shareButton.action = #selector(share)
        addSubview(shareButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ surface: IOSurface) {
        imageSize = CGSize(width: surface.width, height: surface.height)
        imageLayer.contents = surface
        relayout()
    }

    /// Прямоугольник показанной (повёрнутой) картинки в координатах вида.
    var displayedRect: CGRect {
        let rotated = quarterTurns % 2 == 0 ? imageSize : CGSize(width: imageSize.height, height: imageSize.width)
        let fit = min(bounds.width / rotated.width, bounds.height / rotated.height) * 0.95 * zoom
        let size = CGSize(width: rotated.width * fit, height: rotated.height * fit)
        return CGRect(x: bounds.midX - size.width / 2 + offset.x, y: bounds.midY - size.height / 2 + offset.y,
                      width: size.width, height: size.height)
    }

    func relayout() {
        let rect = displayedRect
        let scale = (quarterTurns % 2 == 0 ? rect.width / imageSize.width : rect.width / imageSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
        imageLayer.position = CGPoint(x: rect.midX, y: rect.midY)
        imageLayer.transform = CATransform3DMakeRotation(-CGFloat(quarterTurns) * .pi / 2, 0, 0, 1)
        CATransaction.commit()
        if overlayOnImage {
            overlay.autoresizingMask = []
            overlay.frame = rect
        }
        overlay.setContentsRectNeedsUpdate()
        placeShareButton()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    // RECT=points — прямоугольник в пунктах вида; иначе единичные координаты, ось Y сверху вниз (UNIT_Y_UP=1 — снизу вверх).
    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        let rect = displayedRect
        log("contentsRect запрошен: \(rect.integral) в \(bounds.size)")
        if overlayOnImage { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if ProcessInfo.processInfo.environment["RECT"] == "points" { return rect }
        let y = flipUnitY ? (bounds.height - rect.maxY) / bounds.height : rect.minY / bounds.height
        return CGRect(x: rect.minX / bounds.width, y: y, width: rect.width / bounds.width, height: rect.height / bounds.height)
    }

    /// Карта: где оверлей видит текст (# — текст), строки сверху вниз; рамкой — где картинка на самом деле.
    func textMap() {
        let cols = 80, rows = 24
        let rect = displayedRect
        var out: [String] = []
        for r in 0..<rows {
            var line = ""
            for c in 0..<cols {
                let x = (CGFloat(c) + 0.5) / CGFloat(cols) * bounds.width
                let yUp = bounds.height - (CGFloat(r) + 0.5) / CGFloat(rows) * bounds.height
                let point = CGPoint(x: x, y: overlay.isFlipped ? bounds.height - yUp : yUp)
                let inImage = rect.contains(CGPoint(x: x, y: yUp))
                line += overlay.hasText(at: point) ? "#" : (inImage ? "." : " ")
            }
            out.append("      |" + line + "|")
        }
        log("карта текста (точка — картинка):\n" + out.joined(separator: "\n"))
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
                     forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        log("shouldBeginAt \(point) тип=\(analysisType.rawValue) → \(isLiveMode)")
        return isLiveMode
    }

    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        log("выделено: «\(overlayView.selectedText.prefix(120))»")
    }

    /// Кнопка Live Text (подсветить весь текст) фиксирует режим: ⌘ держать уже не нужно — как в Quick Look.
    var isLatched = false

    func overlayView(_ overlayView: ImageAnalysisOverlayView, highlightSelectedItemsDidChange highlightSelectedItems: Bool) {
        isLatched = highlightSelectedItems
        log("кнопка Live Text: подсветка \(highlightSelectedItems ? "вкл — режим зафиксирован" : "выкл — режим снова по ⌘")")
        if !highlightSelectedItems, !NSEvent.modifierFlags.contains(.command) { isLiveMode = false }
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, liveTextButtonDidChangeToVisible visible: Bool) {
        log("кнопка Live Text видима: \(visible)")
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, willOpen menu: NSMenu) {
        log("меню: " + menu.items.map { "\($0.title)[\($0.tag)]" }.joined(separator: ", "))
    }

    var picker: NSSharingServicePicker?
    /// В интерактивном режиме: меню «Поделиться» — окно уровня 101, панель .screenSaver (1000) его закрывает.
    /// На время меню панель — .statusBar (выше строки меню и Dock), после выбора сервиса — обычный уровень.
    var lowersForSharing = false
    /// Когда выбрали сервис: если вслед за этим активируется другое приложение («Сообщения», «Почта»), сервис
    /// продолжается там — панель уходит с дороги, процесс живёт (иначе вложение пропадает).
    var serviceChosenAt = Date.distantPast
    var workspaceObserver: NSObjectProtocol?

    @objc func share() {
        guard let shareURL, picker == nil else { return }
        log("«Поделиться»: меню у кнопки, панель на уровне \(window?.level.rawValue ?? -1)")
        let picker = NSSharingServicePicker(items: [shareURL])
        picker.delegate = self
        if lowersForSharing, let window, window.level > .statusBar {
            window.level = .statusBar
            log("панель опущена до .statusBar на время меню")
        }
        self.picker = picker
        // Окна сразу после открытия — меню отслеживает события, поэтому таймер в общих режимах цикла.
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in listWindows("через 0,6 с после открытия меню") }
        RunLoop.main.add(timer, forMode: .common)
        picker.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }

    /// Точка картинки (доли от левого верхнего угла неповёрнутой картинки) → точка вида с учётом масштаба и поворота.
    func viewPoint(u: CGFloat, v: CGFloat) -> CGPoint {
        var x = (u - 0.5) * imageSize.width, y = (v - 0.5) * imageSize.height  // y — вниз
        for _ in 0..<quarterTurns { (x, y) = (-y, x) }  // поворот по часовой
        let rect = displayedRect
        let scale = quarterTurns % 2 == 0 ? rect.width / imageSize.width : rect.width / imageSize.height
        let point = CGPoint(x: rect.midX + x * scale, y: rect.midY - y * scale)
        return overlay.isFlipped ? CGPoint(x: point.x, y: bounds.height - point.y) : point
    }

    /// Совпадают ли рамки текста с картинкой: в строках текст есть, в пустом месте — нет.
    func checkAlignment(_ name: String) {
        let probes: [(String, CGFloat, CGFloat, Bool)] = [
            ("«Телефон»", 0.12, 0.225, true), ("«quick brown fox»", 0.2, 0.524, true),
            ("пусто справа внизу", 0.8, 0.85, false), ("пусто между строк", 0.12, 0.29, false),
        ]
        var lines: [String] = []
        for (label, u, v, expected) in probes {
            let point = viewPoint(u: u, v: v)
            let inside = bounds.contains(overlay.isFlipped ? CGPoint(x: point.x, y: bounds.height - point.y) : point)
            let has = overlay.hasText(at: point)
            lines.append("\(label)=\(inside ? (has == expected ? "✓" : "✗ \(has)") : "за краем")")
        }
        log("совпадение \(name) (isFlipped=\(overlay.isFlipped)): " + lines.joined(separator: ", "))
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        log("«Поделиться»: выбрано \(service?.title ?? "ничего (закрыто)")")
        picker = nil
        if service != nil { serviceChosenAt = Date() }
        if lowersForSharing, workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, Date().timeIntervalSince(self.serviceChosenAt) < 3,
                          app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                    window.orderOut(nil)
                    log("активно «\(app?.localizedName ?? "?")» — сервис продолжается там, панель скрыта (процесс жив; выход — Ctrl+C в Терминале)")
                }
            }
        }
        if lowersForSharing, let window {
            // Окна сервисов — обычного уровня (AirDrop — наш процесс, уровень 3; «Сообщения» — другой процесс):
            // на время их работы панель опускается, по завершении — обратно (sharingService(_:didShareItems:)).
            window.level = service == nil ? .screenSaver : .normal
            log("панель — уровень \(window.level.rawValue)")
        }
        if service != nil {
            let timer = Timer(timeInterval: 1.5, repeats: false) { _ in listWindows("через 1,5 с после выбора") }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        log("«\(sharingService.title)»: отправлено")
        restoreAfterSharing()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        let ns = error as NSError
        log("«\(sharingService.title)»: не вышло — \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        restoreAfterSharing()
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        log("«\(sharingService.title)»: спрашивает окно-источник")
        return window
    }

    func restoreAfterSharing() {
        guard lowersForSharing, let window else { return }
        window.level = .screenSaver
        log("панель снова .screenSaver")
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }

    /// Кнопки VisionKit внутри оверлея — для ⌘L ищем «Поиск по изображению».
    func dumpOverlay() {
        func walk(_ view: NSView, _ depth: Int) {
            let label = view.accessibilityLabel() ?? ""
            let title = (view as? NSButton)?.title ?? ""
            log(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame) hidden=\(view.isHidden) «\(label)» «\(title)»")
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        walk(overlay, 0)
    }

    /// Справа от кнопки Live Text, того же размера и на той же высоте; кнопки VisionKit нет — в угол видимой части.
    func placeShareButton() {
        var liveText: NSView?
        func walk(_ view: NSView) {
            if liveText == nil, !view.isHiddenOrHasHiddenAncestor, String(describing: type(of: view)) == "VKImageAnalysisButton" { liveText = view }
            view.subviews.forEach(walk)
        }
        walk(overlay)
        if let liveText {
            let frame = liveText.convert(liveText.bounds, to: self)
            shareButton.frame = frame.offsetBy(dx: frame.width + 8, dy: 0)
        } else {
            let visible = displayedRect.intersection(bounds)
            shareButton.frame = NSRect(x: visible.maxX - 8 - 26, y: visible.minY + 8, width: 26, height: 26)
        }
    }

    /// «Visual Look Up» — `VKCVisualSearchCornerView`, видна, только если на картинке есть что искать.
    func lookUpButton() -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            let text = (view.accessibilityLabel() ?? "").lowercased()
            if found == nil, !view.isHiddenOrHasHiddenAncestor,
               String(describing: type(of: view)).contains("VisualSearch") || text.contains("look up") || text.contains("поиск") {
                found = view
            }
            view.subviews.forEach(walk)
        }
        walk(overlay)
        return found
    }

    /// Нажать найденную кнопку: как элемент управления, через доступность или щелчком в её центр.
    func press(_ view: NSView) {
        if let control = view as? NSControl {
            log("нажатие: performClick \(type(of: view))")
            control.performClick(nil)
        } else if view.accessibilityPerformPress() {
            log("нажатие: accessibilityPerformPress \(type(of: view))")
        } else if let window = view.window {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            log("нажатие: щелчок в \(point) \(type(of: view))")
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        }
    }
}

// MARK: - align

func capture(_ window: NSWindow, _ name: String, _ dir: String) {
    let path = "\(dir)/\(name).png"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
    try? process.run()
    process.waitUntilExit()
    log("снимок \(path)")
}

func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

@MainActor func align(_ paths: [String]) async {
    let dir = ProcessInfo.processInfo.environment["OUT"] ?? FileManager.default.currentDirectoryPath
    let (_, image) = images(paths)[0]
    let display = surface(from: scaled(image, maxSide: 2560))
    let panel = ProbePanel(contentRect: NSRect(x: 160, y: 140, width: 1200, height: 800),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    let stage = StageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    panel.contentView = stage
    stage.show(display)
    panel.orderFrontRegardless()
    let states: [(String, CGFloat, CGPoint, Int)] = [
        ("1-fit", 1, .zero, 0), ("2-zoom", 2.2, CGPoint(x: 420, y: -260), 0),
        ("3-rot90", 1, .zero, 1), ("4-rot180", 1, .zero, 2), ("5-rot90-zoom", 1.8, CGPoint(x: -150, y: 200), 1),
        ("7-fit-again", 1, .zero, 0),
    ]
    for (name, zoom, offset, turns) in states {
        stage.zoom = zoom
        stage.offset = offset
        stage.quarterTurns = turns
        stage.relayout()
        stage.overlay.analysis = await analyze(display, quarterTurns: turns)
        stage.isLiveMode = true
        stage.overlay.selectableItemsHighlighted = true
        await sleep(0.8)
        // Выделение программно: VisionKit рисует его там, где, по его мнению, текст, — видно на снимке.
        let text = stage.overlay.text
        let ranges = ["Телефон: +7 495 123-45-67", "quick brown fox"].compactMap { text.range(of: $0) }
        stage.overlay.selectedRanges = ranges
        log("выделено программно \(ranges.count) из 2: «\(stage.overlay.selectedText.replacingOccurrences(of: "\n", with: " | "))»")
        await sleep(0.4)
        capture(panel, name, dir)
    }
    stage.zoom = 1
    stage.offset = .zero
    stage.quarterTurns = 0
    stage.relayout()
    stage.overlay.analysis = await analyze(display)
    stage.overlay.selectableItemsHighlighted = false
    stage.isLiveMode = true
    await sleep(1.0)
    capture(panel, "6-mode-buttons", dir)
    stage.dumpOverlay()
    exit(0)
}

// MARK: - sharetest

@MainActor func shareTest(_ paths: [String]) async {
    let (_, image) = images(paths)[0]
    let panel = ProbePanel(contentRect: NSRect(x: 160, y: 140, width: 1200, height: 800),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let stage = StageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    stage.shareURL = fileURL(paths, image)
    panel.contentView = stage
    stage.show(surface(from: scaled(image, maxSide: 2560)))
    for level in [NSWindow.Level.screenSaver, .statusBar] {
        panel.level = level
        panel.orderFrontRegardless()
        panel.makeKey()
        stage.isLiveMode = true
        await sleep(0.5)
        stage.share()
        await sleep(1.2)
        stage.picker?.close()
        await sleep(0.5)
    }
    exit(0)
}

// MARK: - clicktest: доходит ли мышь до картинки сквозь оверлей

@MainActor func clickTest() async {
    let panel = ProbePanel(contentRect: NSRect(x: 160, y: 140, width: 1200, height: 800),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    let stage = StageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    panel.contentView = stage
    let display = surface(from: scaled(testImage(), maxSide: 2560))
    stage.show(display)
    panel.orderFrontRegardless()
    panel.makeKey()
    stage.overlay.analysis = await analyze(display)
    func drag(from: CGPoint, to: CGPoint) async {
        let a = stage.viewPoint(u: from.x, v: from.y), b = stage.viewPoint(u: to.x, v: to.y)
        func send(_ type: NSEvent.EventType, _ p: CGPoint) {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(e, atStart: false)
        }
        send(.leftMouseDown, a)
        for i in 1...6 { send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / 6, y: a.y + (b.y - a.y) * CGFloat(i) / 6)) }
        send(.leftMouseUp, b)
        await sleep(0.6)
    }
    for mode in [false, true, false] {
        stage.isLiveMode = mode
        await sleep(0.3)
        let before = stage.offset
        log("— режим \(mode): тяну по строке «Телефон»")
        await drag(from: CGPoint(x: 0.06, y: 0.225), to: CGPoint(x: 0.28, y: 0.225))
        log("  сдвиг картинки: \(stage.offset.x - before.x), \(stage.offset.y - before.y); выделено: «\(stage.overlay.selectedText)»")
    }
    exit(0)
}

// MARK: - cardtest: что за окна открывают телефон и ссылка

@MainActor func dumpAppWindows(_ title: String) {
    var lines: [String] = []
    for w in NSApp.windows where w.isVisible {
        lines.append("    \(type(of: w)) уровень=\(w.level.rawValue) ключевое=\(w.isKeyWindow) родитель=\(w.parent.map { "\(type(of: $0))" } ?? "-") \(w.frame.integral)")
    }
    log("окна приложения (\(title)):\n" + lines.joined(separator: "\n"))
    listWindows(title)
}

@MainActor func cardTest() async {
    let panel = ProbePanel(contentRect: NSRect(x: 160, y: 140, width: 1200, height: 800),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    let stage = StageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    panel.contentView = stage
    let display = surface(from: scaled(testImage(), maxSide: 2560))
    stage.show(display)
    panel.orderFrontRegardless()
    panel.makeKey()
    stage.overlay.analysis = await analyze(display)
    stage.isLiveMode = true
    await sleep(0.6)
    var elements: [NSView] = []
    func walk(_ v: NSView) {
        if String(describing: type(of: v)) == "VKCDataDetectorElementView" { elements.append(v) }
        v.subviews.forEach(walk)
    }
    walk(stage.overlay)
    log("распознанных данных: \(elements.count)")
    for (i, element) in elements.enumerated() {
        let point = element.convert(NSPoint(x: element.bounds.midX, y: element.bounds.midY), to: nil)
        log("— щелчок по данным \(i + 1) в \(point)")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(e, atStart: false)
        }
        await sleep(1.5)
        dumpAppWindows("после щелчка \(i + 1)")
        // Закрыть всё, что открылось, — Esc ключевому окну и orderOut прочим.
        for w in NSApp.windows where w.isVisible && w !== panel {
            log("    закрываю \(type(of: w)): orderOut")
            w.orderOut(nil)
        }
        await sleep(0.5)
    }
    exit(0)
}

// MARK: - pilltest: «пилюли» быстрых действий — открыть без мыши, закрыть так, чтобы VisionKit знал

@MainActor func describe(_ view: NSView) -> String {
    var chain: [String] = []
    var cls: AnyClass? = type(of: view)
    while let c = cls {
        chain.append(String(describing: c))
        if chain.last == "NSView" || chain.count > 5 { break }
        cls = class_getSuperclass(c)
    }
    let role = view.accessibilityRole()?.rawValue ?? "-"
    let gestures = view.gestureRecognizers.map { String(describing: type(of: $0)) }
    return "\(chain.joined(separator: ":")) \(view.frame.integral) hidden=\(view.isHidden) role=\(role) «\(view.accessibilityLabel() ?? "")» «\(view.accessibilityTitle() ?? "")» ax=\(view.isAccessibilityElement()) gr=\(gestures)"
}

@MainActor func dumpViews(_ root: NSView, _ title: String) {
    var lines: [String] = []
    func walk(_ view: NSView, _ depth: Int) {
        lines.append(String(repeating: "  ", count: depth) + describe(view))
        view.subviews.forEach { walk($0, depth + 1) }
    }
    walk(root, 1)
    log("виды (\(title)):\n" + lines.joined(separator: "\n"))
}

/// Дерево доступности (то, что видят VoiceOver и AX): роль, подпись, заголовок, действия.
@MainActor func dumpAX(_ root: Any, _ title: String) {
    var lines: [String] = []
    func walk(_ element: Any, _ depth: Int) {
        guard lines.count < 300, let el = element as? NSAccessibilityProtocol else {
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: element)) (не элемент доступности)")
            return
        }
        let role = el.accessibilityRole()?.rawValue ?? "-"
        let label = el.accessibilityLabel() ?? ""
        let title = el.accessibilityTitle() ?? ""
        let value = (el.accessibilityValue()).map { "\($0)" } ?? ""
        lines.append(String(repeating: "  ", count: depth) + "\(type(of: element)) role=\(role) «\(label)» «\(title)» «\(value.prefix(60))»")
        for child in el.accessibilityChildren() ?? [] { walk(child, depth + 1) }
    }
    walk(root, 1)
    log("доступность (\(title)):\n" + lines.joined(separator: "\n"))
}

/// Первый элемент доступности, у которого подпись или заголовок содержит что-то из `names`.
@MainActor func findAX(_ root: Any, _ names: [String]) -> NSAccessibilityProtocol? {
    guard let el = root as? NSAccessibilityProtocol else { return nil }
    let text = ((el.accessibilityLabel() ?? "") + " " + (el.accessibilityTitle() ?? "")).lowercased()
    if names.contains(where: { text.contains($0.lowercased()) }) { return el }
    for child in el.accessibilityChildren() ?? [] {
        if let found = findAX(child, names) { return found }
    }
    return nil
}

@MainActor func methods(of object: AnyObject, matching words: [String]) -> [String] {
    var result: [String] = []
    var cls: AnyClass? = type(of: object)
    while let c = cls, String(describing: c) != "NSObject", String(describing: c) != "NSViewController", String(describing: c) != "NSResponder" {
        var count: UInt32 = 0
        if let list = class_copyMethodList(c, &count) {
            for i in 0..<Int(count) {
                let name = NSStringFromSelector(method_getName(list[i]))
                if words.contains(where: { name.lowercased().contains($0) }) { result.append("\(c).\(name)") }
            }
            free(list)
        }
        cls = class_getSuperclass(c)
    }
    return result
}

/// Все методы класса (и его метакласса), в которых есть одно из слов, — для частных классов DataDetectors/VisionKit.
func classMethods(_ name: String, _ words: [String]) -> [String] {
    guard let cls = NSClassFromString(name) else { return ["\(name): класса нет"] }
    var result: [String] = []
    for (prefix, target) in [("-", cls), ("+", object_getClass(cls)!)] {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(target, &count) else { continue }
        for i in 0..<Int(count) {
            let selector = NSStringFromSelector(method_getName(list[i]))
            if words.isEmpty || words.contains(where: { selector.lowercased().contains($0) }) {
                result.append("\(prefix)\(selector) \(String(cString: method_getTypeEncoding(list[i])!))")
            }
        }
        free(list)
    }
    return result
}

/// DataDetectors на macOS 27: `+[DDActionsManager sharedManager]`, `-requestBubbleClosureUnanchorOnFailure:`,
/// `+[DDActionsManager actionUIClosed]`; у карточки — `-[DDPopover presentationEndedForController:]`.
@MainActor func ddManager() -> NSObject? {
    guard let cls = NSClassFromString("DDActionsManager") as? NSObject.Type else { return nil }
    return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
}

@MainActor func requestBubbleClosure(unanchorOnFailure: Bool = false) -> Bool {
    let close = NSSelectorFromString("requestBubbleClosureUnanchorOnFailure:")
    guard let manager = ddManager(), manager.responds(to: close) else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(manager.method(for: close), to: Fn.self)(manager, close, unanchorOnFailure)
    return true
}

@MainActor func actionUIClosed() -> Bool {
    guard let cls = NSClassFromString("DDActionsManager") as? NSObject.Type else { return false }
    let selector = NSSelectorFromString("actionUIClosed")
    guard cls.responds(to: selector) else { return false }
    _ = cls.perform(selector)
    return true
}

@MainActor func presentationEnded(_ popover: NSPopover) -> Bool {
    let selector = NSSelectorFromString("presentationEndedForController:")
    guard popover.responds(to: selector), let content = popover.contentViewController else { return false }
    _ = popover.perform(selector, with: content)
    return true
}

/// Подмена методов DataDetectors с записью вызовов в лог — чтобы увидеть, на какой проверке «пилюля» молчит.
@MainActor func traceDataDetectors() {
    guard let manager: AnyClass = NSClassFromString("DDActionsManager") else { return }
    let meta: AnyClass = object_getClass(manager)!
    func swap(_ cls: AnyClass, _ name: String, _ make: (IMP) -> Any) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { log("трассировка: \(name) нет"); return }
        let original = method_getImplementation(method)
        method_setImplementation(method, imp_implementationWithBlock(make(original)))
    }
    typealias BoolObj = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
    typealias Bool0 = @convention(c) (AnyObject, Selector) -> Bool
    typealias VoidObj = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    typealias Void0 = @convention(c) (AnyObject, Selector) -> Void
    typealias VoidObjObj = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
    typealias ObjObj = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    swap(meta, "shouldUseActionsWithContext:") { imp in
        let block: @convention(block) (AnyObject, AnyObject?) -> Bool = { this, context in
            let result = unsafeBitCast(imp, to: BoolObj.self)(this, NSSelectorFromString("shouldUseActionsWithContext:"), context)
            log("  DD +shouldUseActionsWithContext → \(result)")
            return result
        }
        return block
    }
    var lastHit = ""
    swap(meta, "hitWindowIsPopover") { imp in
        let block: @convention(block) (AnyObject) -> Bool = { this in
            let result = unsafeBitCast(imp, to: Bool0.self)(this, NSSelectorFromString("hitWindowIsPopover"))
            let name: (NSWindow?) -> String = { $0.map { "\(type(of: $0)) видимо=\($0.isVisible)" } ?? "nil" }
            let underMouse = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
            let line = "\(result) key=\(name(NSApp.keyWindow)) main=\(name(NSApp.mainWindow)) событие=\(name(NSApp.currentEvent?.window)) тип=\(NSApp.currentEvent.map { "\($0.type.rawValue)" } ?? "-") подмышью=\(name(NSApp.window(withWindowNumber: underMouse)))"
            if line != lastHit { log("  DD +hitWindowIsPopover → \(line)"); lastHit = line }
            return result
        }
        return block
    }
    swap(meta, "actionUIOpenedWithContext:") { imp in
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { this, context in
            log("  DD +actionUIOpenedWithContext")
            unsafeBitCast(imp, to: VoidObj.self)(this, NSSelectorFromString("actionUIOpenedWithContext:"), context)
        }
        return block
    }
    swap(meta, "actionUIClosed") { imp in
        let block: @convention(block) (AnyObject) -> Void = { this in
            log("  DD +actionUIClosed")
            unsafeBitCast(imp, to: Void0.self)(this, NSSelectorFromString("actionUIClosed"))
        }
        return block
    }
    swap(meta, "didUseActions") { imp in
        let block: @convention(block) (AnyObject) -> Void = { this in
            log("  DD +didUseActions")
            unsafeBitCast(imp, to: Void0.self)(this, NSSelectorFromString("didUseActions"))
        }
        return block
    }
    swap(meta, "displayUIForContext:additionalMenuItems:") { imp in
        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { this, context, items in
            log("  DD +displayUIForContext:additionalMenuItems:")
            unsafeBitCast(imp, to: VoidObjObj.self)(this, NSSelectorFromString("displayUIForContext:additionalMenuItems:"), context, items)
        }
        return block
    }
    swap(manager, "runActionForDictionary:") { imp in
        let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { this, dictionary in
            let keys = (dictionary as? NSDictionary)?.allKeys.map { "\($0)" }.sorted() ?? []
            log("  DD -runActionForDictionary: ключи \(keys)")
            let result = unsafeBitCast(imp, to: ObjObj.self)(this, NSSelectorFromString("runActionForDictionary:"), dictionary)
            log("  DD -runActionForDictionary → \(result.map { "\(type(of: $0))" } ?? "nil")")
            return result
        }
        return block
    }
    for (cls, name) in [(manager, "setUIElement:isInUse:"), (manager, "requestBubbleClosureUnanchorOnFailure:")] {
        _ = (cls, name)
    }
    for name in ["requestBubbleClosureUnanchorOnFailure:"] {
        swap(manager, name) { imp in
            typealias VoidBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            let block: @convention(block) (AnyObject, Bool) -> Void = { this, flag in
                log("  DD -\(name) \(flag)")
                unsafeBitCast(imp, to: VoidBool.self)(this, NSSelectorFromString(name), flag)
            }
            return block
        }
    }
    for name in ["unanchorBubbles"] {
        swap(manager, name) { imp in
            let block: @convention(block) (AnyObject) -> Void = { this in
                log("  DD -\(name)")
                unsafeBitCast(imp, to: Void0.self)(this, NSSelectorFromString(name))
            }
            return block
        }
    }
    if let button: AnyClass = NSClassFromString("VKCActionInfoButton") {
        for name in ["_vk_performAction", "performDefaultElementAction"] {
            swap(button, name) { imp in
                let block: @convention(block) (AnyObject) -> Void = { this in
                    log("  VK -\(name) state=\((this as? NSButton)?.state.rawValue ?? -1)")
                    unsafeBitCast(imp, to: Void0.self)(this, NSSelectorFromString(name))
                }
                return block
            }
        }
        swap(button, "mouseDown:") { imp in
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { this, event in
                log("  VK -mouseDown: state=\((this as? NSButton)?.state.rawValue ?? -1)")
                unsafeBitCast(imp, to: VoidObj.self)(this, NSSelectorFromString("mouseDown:"), event)
                log("  VK -mouseDown: конец, state=\((this as? NSButton)?.state.rawValue ?? -1)")
            }
            return block
        }
    }
    if let popover: AnyClass = NSClassFromString("DDPopover") {
        swap(popover, "popoverShouldClose:") { imp in
            let block: @convention(block) (AnyObject, AnyObject?) -> Bool = { this, sender in
                let result = unsafeBitCast(imp, to: BoolObj.self)(this, NSSelectorFromString("popoverShouldClose:"), sender)
                log("  DDPopover -popoverShouldClose → \(result)")
                return result
            }
            return block
        }
        swap(popover, "presentRelativeToRect:ofView:preferredEdge:") { imp in
            typealias Present = @convention(c) (AnyObject, Selector, CGRect, AnyObject?, UInt) -> Void
            let block: @convention(block) (AnyObject, CGRect, AnyObject?, UInt) -> Void = { this, rect, view, edge in
                log("  DDPopover -presentRelativeToRect \(rect.integral) край \(edge)")
                unsafeBitCast(imp, to: Present.self)(this, NSSelectorFromString("presentRelativeToRect:ofView:preferredEdge:"), rect, view, edge)
            }
            return block
        }
    }
    log("трассировка DataDetectors включена")
}

/// Показанные карточки — через уведомления NSPopover.
@MainActor final class PopoverWatch {
    var shown: [NSPopover] = []
    init() {
        NotificationCenter.default.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let popover = note.object as? NSPopover
            MainActor.assumeIsolated {
                guard let popover else { return }
                self.shown.append(popover)
                let content = popover.contentViewController.map { "\(type(of: $0))" } ?? "-"
                let delegate = popover.delegate.map { "\(type(of: $0))" } ?? "-"
                let presenting = popover.contentViewController?.presentingViewController.map { "\(type(of: $0))" } ?? "-"
                log("  ↑ карточка показана: \(content), behavior=\(popover.behavior.rawValue), delegate=\(delegate), presenting=\(presenting)")
            }
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let popover = note.object as? NSPopover
            MainActor.assumeIsolated {
                self.shown.removeAll { $0 === popover }
                log("  ↓ карточка закрыта (didClose)")
            }
        }
    }
    var isShown: Bool { shown.contains { $0.isShown } }
}

/// Окна других процессов на уровнях между строкой меню и панелью (так выглядит просмотр ссылки).
func foreignPopups() -> [(number: Int, pid: Int, owner: String, layer: Int, bounds: String)] {
    let own = Int(ProcessInfo.processInfo.processIdentifier)
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        guard pid != own, layer > 25, layer < 1000 else { return nil }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        return (w[kCGWindowNumber as String] as? Int ?? 0, pid, w[kCGWindowOwnerName as String] as? String ?? "?", layer,
                "\(b["Width"] ?? 0)x\(b["Height"] ?? 0) @\(b["X"] ?? 0),\(b["Y"] ?? 0)")
    }
}

/// Средняя яркость полос экрана: строка меню (верх 30 pt) и Dock (низ 60 pt, середина) — снимок не сохраняется,
/// только числа: тёмная панель поверх — яркость близка к нулю.
func measureCover(_ title: String) {
    let screen = NSScreen.main!.frame
    let bounds = CGDisplayBounds(CGMainDisplayID())
    // Снимок всего экрана (как в прошлом замере уровней), доля красного — в полосах; снимок удаляется.
    let path = NSTemporaryDirectory() + "cover-full.png"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", path]
    try? process.run()
    process.waitUntilExit()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let rep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
    func brightness(_ rect: CGRect) -> String {
        guard let rep else { return "нет снимка" }
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        var red = 0.0, count = 0.0
        for y in stride(from: Int(rect.minY * scale), to: Int(rect.maxY * scale), by: 4) {
            for x in stride(from: Int(rect.minX * scale), to: Int(rect.maxX * scale), by: 4) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.4 { red += 1 }
                count += 1
            }
        }
        return String(format: "%.0f%% красного", red / max(count, 1) * 100)
    }
    _ = screen
    let menu = CGRect(x: bounds.minX + 200, y: bounds.minY, width: bounds.width - 400, height: 30)
    let dock = CGRect(x: bounds.midX - 300, y: bounds.maxY - 60, width: 600, height: 55)
    let middle = CGRect(x: bounds.midX - 300, y: bounds.midY - 30, width: 600, height: 60)
    log("яркость (\(title)): строка меню \(brightness(menu)), Dock \(brightness(dock)), середина \(brightness(middle))")
}

@MainActor func pillTest() async {
    let watch = PopoverWatch()
    if ProcessInfo.processInfo.environment["TRACE"] == "1" { traceDataDetectors() }
    // FULL=1 — панель на весь экран (как просмотр): видно, закрывает ли она строку меню и Dock.
    let full = ProcessInfo.processInfo.environment["FULL"] == "1"
    let frame = full ? NSScreen.main!.frame : NSRect(x: 160, y: 140, width: 1200, height: 800)
    let panel = ProbePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    let stage = StageView(frame: NSRect(origin: .zero, size: frame.size))
    panel.contentView = stage
    let display = surface(from: scaled(testImage(), maxSide: 2560))
    stage.show(display)
    // NOKEY=1 — как режим «следовать»: панель не берёт клавиатуру и не становится ключевой.
    let noKey = ProcessInfo.processInfo.environment["NOKEY"] == "1"
    panel.takesKeyboard = !noKey
    panel.orderFrontRegardless()
    if !noKey { panel.makeKey() }
    log("панель ключевая: \(panel.isKeyWindow), уровень \(panel.level.rawValue)")
    stage.overlay.analysis = await analyze(display)
    stage.isLiveMode = true
    stage.overlay.selectableItemsHighlighted = true
    await sleep(1.0)
    if ProcessInfo.processInfo.environment["QUIET"] != "1" { dumpViews(stage.overlay, "оверлей с подсветкой") }
    if ProcessInfo.processInfo.environment["QUIET"] != "1" { dumpAX(stage.overlay, "оверлей") }

    // «Пилюли» — кнопки VKCActionInfoButton (NSButton) с текстом данных в заголовке; данные на самой картинке —
    // VKCDataDetectorElementView (AXButton, текст — в accessibilityValue). DETECTOR=1 — жать по данным на картинке.
    let viaDetector = ProcessInfo.processInfo.environment["DETECTOR"] == "1"
    func pill(_ words: [String]) -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            guard found == nil else { return }
            let name = String(describing: type(of: view))
            // Телефон пишется с неразрывными дефисами и пробелами — сравниваем только буквы и цифры.
            func plain(_ text: String) -> String { String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "." }) }
            let text: String
            if viaDetector, name == "VKCDataDetectorElementView" {
                text = view.accessibilityValue() as? String ?? ""
            } else if !viaDetector, name == "VKCActionInfoButton", let button = view as? NSButton {
                text = button.title + " " + (button.accessibilityTitle() ?? "")
            } else {
                text = ""
            }
            if !text.isEmpty, words.contains(where: { plain(text).contains(plain($0)) }) { found = view }
            view.subviews.forEach(walk)
        }
        walk(stage.overlay)
        return found
    }
    // EVENTS=1 — щелчок событиями мыши через очередь приложения (как настоящий: mouseDown/mouseUp в окно),
    // а не performClick: так видно, что делает с ним монитор и какой currentEvent у VisionKit.
    let viaEvents = ProcessInfo.processInfo.environment["EVENTS"] == "1"
    var eventNumber = 100
    func press(_ view: NSView?, _ what: String) async {
        guard let view else { log("— \(what): не найдено"); return }
        if viaEvents, let window = view.window {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                eventNumber += 1
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: pressure) {
                    NSApp.postEvent(event, atStart: false)
                }
                await sleep(0.05)
            }
            log("— \(what): события мыши в \(point) (\(type(of: view)))")
        } else if let button = view as? NSButton {
            button.performClick(nil)
            log("— \(what): performClick (\(type(of: view)))")
        } else {
            log("— \(what): accessibilityPerformPress → \(view.accessibilityPerformPress()) (\(type(of: view)))")
        }
        await sleep(1.2)
        log("  карточка открыта: \(watch.isShown); чужие всплывающие: \(foreignPopups().map { "\($0.owner) \($0.layer) \($0.bounds)" })")
    }
    let phoneWords = ["123-45-67"]
    func callClass(_ cls: String, _ name: String) -> String {
        guard let type = NSClassFromString(cls) as? NSObject.Type else { return "\(cls) нет" }
        let selector = NSSelectorFromString(name)
        guard type.responds(to: selector) else { return "\(cls).\(name) нет" }
        _ = type.perform(selector)
        return "ok"
    }
    func rvPresenter() -> NSObject? {
        (NSClassFromString("RVPresenter") as? NSObject.Type)?.perform(NSSelectorFromString("sharedPresenter"))?.takeUnretainedValue() as? NSObject
    }
    func callPresenter(_ name: String, _ argument: AnyObject? = nil) -> String {
        guard let presenter = rvPresenter() else { return "RVPresenter нет" }
        let selector = NSSelectorFromString(name)
        guard presenter.responds(to: selector) else { return "\(name) нет" }
        if let argument {
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
            return "\(unsafeBitCast(presenter.method(for: selector), to: Fn.self)(presenter, selector, argument))"
        }
        _ = presenter.perform(selector)
        return "ok"
    }
    // LINKTOGGLE=1 — «пилюля» ссылки как переключатель: пока просмотр ссылки открыт, щелчок по панели закрывает
    // его (requestBubbleClosure) и поглощается целиком — нажатие и отпускание. Пять щелчков подряд.
    if ProcessInfo.processInfo.environment["LINKTOGGLE"] == "1" {
        func previewOpen() -> Bool {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.contains { w in
                let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
                let layer = w[kCGWindowLayer as String] as? Int ?? 0
                return layer > 25 && NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == "com.apple.quicklook.ui.helper"
            }
        }
        var swallowUp = false
        let swallow = ProcessInfo.processInfo.environment["NOSWALLOW"] != "1"
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated {
                guard event.window === panel else { return event }
                if event.type == .leftMouseUp {
                    if swallowUp { swallowUp = false; return nil }
                    return event
                }
                guard previewOpen() else {
                    // Режим «следовать» (NOKEY=1): панель берёт клавиатуру на время щелчка и отдаёт через 1 с.
                    if noKey {
                        panel.takesKeyboard = true
                        panel.makeKey()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            panel.takesKeyboard = false
                            NSApp.deactivate()
                        }
                    }
                    return event
                }
                _ = requestBubbleClosure()
                log("  монитор: просмотр ссылки открыт — закрываю\(swallow ? ", щелчок поглощён" : ", щелчок пропущен")")
                guard swallow else { return event }
                swallowUp = true
                return nil
            }
        }
        func previewPlace() -> String {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list {
                let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
                guard NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == "com.apple.quicklook.ui.helper",
                      let layer = w[kCGWindowLayer as String] as? Int, layer > 25 else { continue }
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                return "уровень \(layer) @\(b["X"] ?? 0),\(b["Y"] ?? 0)"
            }
            return "-"
        }
        for click in 1...5 {
            await press(pill(["github.com"]), "ссылка, щелчок \(click)")
            await sleep(1.6)
            log("  просмотр ссылки открыт: \(previewOpen()) \(previewPlace()); панель ключевая \(panel.isKeyWindow)")
        }
        exit(0)
    }
    // LINK=1 — сначала ссылка: появился ли просмотр (окна других процессов, любой уровень) и что его закрывает.
    if ProcessInfo.processInfo.environment["LINK"] == "1" {
        func foreign() -> [Int: String] {
            let own = Int(ProcessInfo.processInfo.processIdentifier)
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            var result: [Int: String] = [:]
            for w in list {
                let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
                guard pid != own, let number = w[kCGWindowNumber as String] as? Int else { continue }
                let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let bundle = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? "?"
                result[number] = "\(w[kCGWindowOwnerName as String] ?? "?") (\(bundle)) уровень \(w[kCGWindowLayer as String] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0) @\(b["X"] ?? 0),\(b["Y"] ?? 0)"
            }
            return result
        }
        let before = foreign()
        let trick = ProcessInfo.processInfo.environment["KEYTRICK"] ?? ""
        func keyState() -> String {
            "панель ключевая \(panel.isKeyWindow) (на деле \(panel.pretendKey ? "?" : "\(panel.isKeyWindow)")), NSApp.keyWindow \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil"), NSApp.isActive \(NSApp.isActive), процесс активен \(NSRunningApplication.current.isActive)"
        }
        switch trick {
        case "pretend":
            panel.pretendKey = true
        case "makekey", "makekey-quick":
            panel.takesKeyboard = true
            panel.makeKey()
        case "monitor":
            // Как в Ementium: ключевой панель становится в мониторе щелчков, если щёлкнули по «пилюле» или данным.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                MainActor.assumeIsolated {
                    guard event.window === panel, let root = panel.contentView?.superview else { return event }
                    var view = root.hitTest(event.locationInWindow)
                    while let current = view {
                        let name = String(describing: type(of: current))
                        if name.contains("ActionInfoButton") || name.contains("DataDetectorElement") {
                            panel.takesKeyboard = true
                            panel.makeKey()
                            log("монитор: щелчок по \(name) — панель ключевая: \(panel.isKeyWindow)")
                            break
                        }
                        view = current.superview
                    }
                    return event
                }
            }
        default:
            break
        }
        if !trick.isEmpty { log("приём \(trick): \(keyState())") }
        let phonePill = ProcessInfo.processInfo.environment["PILL"] == "phone"
        await press(pill(phonePill ? ["123-45-67"] : ["github.com"]), phonePill ? "телефон" : "ссылка")
        if trick == "makekey-quick" {
            // Клавиатуру отдаём сразу после щелчка — окна ссылки ещё нет.
            panel.takesKeyboard = false
            NSApp.deactivate()
            log("отдала клавиатуру сразу после щелчка: \(keyState())")
        }
        await sleep(1.5)
        var appeared = foreign().filter { before[$0.key] == nil }
        log("новые окна других процессов: \(appeared.values.sorted())")
        if phonePill {
            log("карточка открыта: \(watch.isShown); \(keyState())")
            await sleep(1.0)
            log("через секунду карточка открыта: \(watch.isShown)")
            exit(0)
        }
        switch trick {
        case "pretend":
            panel.pretendKey = false
            await sleep(0.5)
            log("перестала сказываться ключевой: \(keyState()); окно ссылки \(appeared.keys.allSatisfy { foreign()[$0] != nil } ? "открыто" : "закрылось")")
        case "makekey", "monitor":
            panel.takesKeyboard = false
            NSApp.deactivate()
            await sleep(0.5)
            log("отдала клавиатуру (deactivate): \(keyState()); окно ссылки \(appeared.keys.allSatisfy { foreign()[$0] != nil } ? "открыто" : "закрылось")")
        default:
            break
        }
        let analysis = stage.overlay.analysis
        let steps: [(String, () -> Void)] = [
            ("панель .statusBar и замер строки меню и Dock", {
                // Сплошной красный фон без картинки — однозначно видно, что поверх чего.
                stage.layer?.backgroundColor = NSColor.systemRed.cgColor
                stage.imageLayer.isHidden = true
                stage.overlay.isHidden = true
                Task { @MainActor in
                    for level in [NSWindow.Level.screenSaver, .statusBar, NSWindow.Level(rawValue: 100)] {
                        panel.level = level
                        await sleep(0.6)
                        measureCover("панель \(level.rawValue), просмотр ссылки \(foreignPopups().isEmpty ? "не виден в 25…1000" : "открыт")")
                    }
                }
            }),
            ("тот же analysis ещё раз", { stage.overlay.analysis = stage.overlay.analysis }),
            ("nil и сразу тот же analysis", { stage.overlay.analysis = nil; stage.overlay.analysis = analysis }),
            ("nil, тот же, снова nil", { stage.overlay.analysis = nil; stage.overlay.analysis = analysis; stage.overlay.analysis = nil }),
            ("nil, тот же, nil следующим проходом", {
                log("  ставлю анализ заново")
                stage.overlay.analysis = nil; stage.overlay.analysis = analysis
                DispatchQueue.main.async { log("  убираю анализ"); stage.overlay.analysis = nil }
            }),
            ("setSupplementaryInterfaceHidden(true)", { stage.overlay.setSupplementaryInterfaceHidden(true, animated: false) }),
            ("selectableItemsHighlighted = false", { stage.overlay.selectableItemsHighlighted = false }),
            ("resetSelection", { stage.overlay.resetSelection() }),
            ("analysis = nil", { stage.overlay.analysis = nil }),
            ("analysis = прежний", { stage.overlay.analysis = analysis }),
            ("requestBubbleClosureUnanchorOnFailure:NO", { _ = requestBubbleClosure() }),
            ("requestBubbleClosure и сразу analysis = nil", { _ = requestBubbleClosure(); stage.overlay.analysis = nil }),
            ("щелчок по панели", {
                for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                    if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 600, y: 400), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 900, clickCount: 1, pressure: pressure) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
            }),
            ("orderOut панели", { panel.orderOut(nil) }),
        ]
        let only = ProcessInfo.processInfo.environment["STEP"]
        for (name, step) in steps where !appeared.isEmpty && (only == nil || name.hasPrefix(only!)) {
            step()
            // Когда закрылся: опрос каждые 50 мс (до 1 с).
            var closedAfter: Double?
            for tick in 1...20 where closedAfter == nil && !name.hasPrefix("панель .statusBar") {
                await sleep(0.05)
                if appeared.keys.allSatisfy({ foreign()[$0] == nil }) { closedAfter = Double(tick) * 0.05 }
            }
            if let closedAfter { log("  закрылся через \(String(format: "%.2f", closedAfter)) с") }
            await sleep(name.hasPrefix("панель .statusBar") ? 4.0 : 0.2)
            let now = foreign()
            let gone = appeared.keys.filter { now[$0] == nil }
            log("— \(name): \(gone.isEmpty ? "просмотр остался" : "ЗАКРЫЛСЯ")")
            gone.forEach { appeared[$0] = nil }
        }
        exit(0)
    }
    // MONITOR=1 — как в Ementium: пока карточка открыта, щелчок по панели её закрывает (close) и поглощается;
    // открытые «прочие» окна (не панель и не карточки из списка) — закрываются и щелчок тоже поглощается.
    if ProcessInfo.processInfo.environment["MONITOR"] == "1" {
        ProbePanel.traceEvents = true
        var tracked: [NSPopover] = []
        NotificationCenter.default.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let popover = note.object as? NSPopover
            MainActor.assumeIsolated { if let popover { tracked.append(popover) } }
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let popover = note.object as? NSPopover
            MainActor.assumeIsolated { tracked.removeAll { $0 === popover || !$0.isShown } }
        }
        let mode = ProcessInfo.processInfo.environment["MODE"] ?? "swallow"
        var swallowUp = false
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            MainActor.assumeIsolated {
                guard swallowUp else { return event }
                swallowUp = false
                log("  монитор: отпускание тоже поглощено")
                return nil
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            MainActor.assumeIsolated {
                if let content = panel.contentView, event.window === panel {
                    let hit = content.superview?.hitTest(event.locationInWindow) ?? content.hitTest(event.locationInWindow)
                    log("  монитор: mouseDown → попадание в \(hit.map { "\(type(of: $0))" } ?? "nil"), clickCount \(event.clickCount), номер \(event.eventNumber)")
                    var chain: [String] = []
                    var view = hit
                    while let current = view {
                        if !current.gestureRecognizers.isEmpty {
                            chain.append("\(type(of: current)): \(current.gestureRecognizers.map { "\(type(of: $0)) state=\($0.state.rawValue) enabled=\($0.isEnabled)" })")
                        }
                        view = current.superview
                    }
                    if !chain.isEmpty { log("  монитор: распознаватели жестов по цепочке: \(chain)") }
                } else {
                    log("  монитор: mouseDown в другое окно: \(event.window.map { "\(type(of: $0))" } ?? "nil")")
                }
                guard event.window === panel else { return event }
                let shown = tracked.filter(\.isShown)
                if !shown.isEmpty, mode == "passthrough" {
                    log("  монитор: карточка открыта — щелчок пропущен к VisionKit, close следом")
                    DispatchQueue.main.async { shown.filter(\.isShown).forEach { $0.close() } }
                    return event
                }
                if !shown.isEmpty {
                    log("  монитор: карточка открыта — close, щелчок поглощён (ключевое: \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil"))")
                    if mode == "swallowpair" { swallowUp = true }
                    shown.forEach { $0.close() }
                    if ProcessInfo.processInfo.environment["MAKEKEY"] == "1" {
                        panel.makeKey()
                        log("  монитор: панель снова ключевая: \(panel.isKeyWindow)")
                    }
                    return nil
                }
                let popoverWindows = tracked.compactMap { $0.contentViewController?.view.window }
                let others = NSApp.windows.filter { window in
                    window.isVisible && window !== panel && !popoverWindows.contains { $0 === window }
                        && !["StatusBar", "Menu", "ToolTip"].contains { String(describing: type(of: window)).contains($0) }
                }
                if !others.isEmpty {
                    log("  монитор: прочие окна \(others.map { "\(type(of: $0)) alpha=\($0.alphaValue)" }) — закрываю, щелчок поглощён")
                    others.forEach { $0.close() }
                    return nil
                }
                return event
            }
        }
        for click in 1...6 {
            log("  перед щелчком \(click): ключевое \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "nil"), панель ключевая \(panel.isKeyWindow)")
            await press(pill(phoneWords), "телефон, щелчок \(click)")
            log("  окна приложения: \(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))" })")
        }
        exit(0)
    }
    // Способы закрыть открытую карточку; каждый — затем один щелчок по «пилюле»: открылась ли с первого раза.
    let ways: [String: (NSPopover) -> String] = [
        "closeAll": { _ in callClass("RVPopoverPresenter", "closeAll") },
        "tryCloseDD": { popover in
            guard let context = popover.value(forKey: "_ddcontext") as AnyObject? else { return "нет _ddcontext" }
            return callPresenter("tryCloseAllPopoverForDDContext:", context)
        },
        "contentChanged": { _ in callPresenter("contentChanged") },
        "contentMoved": { _ in callPresenter("contentMoved") },
        "close": { popover in popover.close(); return "" },
        "close+makeKey": { popover in
            popover.close()
            panel.makeKey()
            return "панель ключевая: \(panel.isKeyWindow)"
        },
        // Щелчок по «пилюле» доходит до VisionKit (карточка остаётся), сразу за ним — close().
        "click+close": { popover in
            (pill(phoneWords) as? NSButton)?.performClick(nil)
            popover.close()
            return "щелчок + close"
        },
        "click+delayclose": { popover in
            (pill(phoneWords) as? NSButton)?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { popover.close() }
            return "щелчок + close через 0,3 с"
        },
        "close+closeAll": { popover in popover.close(); return callClass("RVPopoverPresenter", "closeAll") },
    ]
    let order = (ProcessInfo.processInfo.environment["WAYS"] ?? "closeAll,tryCloseDD,contentChanged,contentMoved,close+closeAll").split(separator: ",").map(String.init)
    for name in order {
        guard let way = ways[name] else { continue }
        if !watch.isShown { await press(pill(phoneWords), "телефон (открыть перед «\(name)»)") }
        guard let popover = watch.shown.last(where: \.isShown) else {
            log("— «\(name)»: карточка не открылась — дальше этот прогон не показателен"); break
        }
        log("— закрываю: \(name) → \(way(popover))")
        await sleep(0.8)
        log("  карточка открыта: \(watch.isShown)")
        if watch.isShown { continue }
        if let wait = Double(ProcessInfo.processInfo.environment["WAIT"] ?? "") { log("  жду \(wait) с"); await sleep(wait) }
        for click in 1...4 where !watch.isShown {
            await press(pill(phoneWords), "телефон после «\(name)», щелчок \(click)")
        }
    }
    if let shown = watch.shown.last(where: \.isShown) { shown.close(); await sleep(0.6) }

    // Ссылка: открывается ли просмотр, чей он и что его закрывает.
    let linkWords = ["github.com"]
    await press(pill(linkWords), "ссылка")
    var preview = foreignPopups().first
    if let window = preview {
        let bundle = NSRunningApplication(processIdentifier: pid_t(window.pid))?.bundleIdentifier ?? "?"
        log("просмотр ссылки: \(window.owner) (\(bundle)) уровень \(window.layer) \(window.bounds)")
        log("— requestBubbleClosure: \(requestBubbleClosure())")
        await sleep(1.0)
        var still = foreignPopups().contains { $0.number == window.number }
        if still {
            log("  остался; actionUIClosed: \(actionUIClosed())")
            await sleep(1.0)
            still = foreignPopups().contains { $0.number == window.number }
        }
        log("  просмотр ссылки \(still ? "остался" : "ЗАКРЫЛСЯ")")
        if !still {
            preview = nil
            await press(pill(linkWords), "ссылка ещё раз")
            preview = foreignPopups().first
        }
    }
    let attempts: [(String, () -> Void)] = [
        ("синтетический ⌘ (postEvent)", {
            for flags in [NSEvent.ModifierFlags.command, []] {
                if let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                            isARepeat: false, keyCode: 55) { NSApp.postEvent(e, atStart: false) }
            }
        }),
        ("resetSelection", { stage.overlay.resetSelection() }),
        ("selectableItemsHighlighted = false", { stage.overlay.selectableItemsHighlighted = false }),
        ("setSupplementaryInterfaceHidden(true)", { stage.overlay.setSupplementaryInterfaceHidden(true, animated: false) }),
        ("isHidden = true", { stage.overlay.isHidden = true }),
        ("analysis = nil", { stage.overlay.analysis = nil }),
        ("щелчок по панели (sendEvent)", {
            let p = NSPoint(x: 600, y: 60)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    panel.sendEvent(e)
                }
            }
        }),
        ("Esc панели (sendEvent)", {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                            isARepeat: false, keyCode: 53) { panel.sendEvent(e) }
            }
        }),
        ("orderOut панели", { panel.orderOut(nil) }),
    ]
    for (name, action) in attempts {
        guard let window = preview else { break }
        action()
        await sleep(0.8)
        let still = foreignPopups().contains { $0.number == window.number }
        log("— \(name): просмотр ссылки \(still ? "остался" : "ЗАКРЫЛСЯ")")
        if !still { preview = nil }
    }
    exit(0)
}

// MARK: - classdump: методы и переменные частных классов (после загрузки VisionKit и DataDetectors)

@MainActor func classDump(_ names: [String]) async {
    // Классы DataDetectors подгружаются вместе с VisionKit — создаём оверлей и анализ, как в просмотре.
    let overlay = ImageAnalysisOverlayView()
    overlay.analysis = await analyze(surface(from: scaled(testImage(), maxSide: 1280)))
    for name in names {
        guard let cls = NSClassFromString(name) else { log("\(name): класса нет"); continue }
        var lines: [String] = ["супер: \(class_getSuperclass(cls).map { String(describing: $0) } ?? "-")"]
        var count: UInt32 = 0
        if let ivars = class_copyIvarList(cls, &count) {
            for i in 0..<Int(count) {
                let ivar = ivars[i]
                lines.append("  ivar \(ivar_getName(ivar).map { String(cString: $0) } ?? "?") \(ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "")")
            }
            free(ivars)
        }
        lines += classMethods(name, []).map { "  " + $0 }
        log("\(name):\n" + lines.joined(separator: "\n"))
    }
    exit(0)
}

// MARK: - overlay (интерактивно)

final class CommandHold {
    var downAt: Date?
    var otherKey = false
}

@MainActor func overlayMode(_ paths: [String], follow: Bool) async {
    let (_, image) = images(paths)[0]
    let screenVersion = scaled(image, maxSide: 2560)
    let display = surface(from: screenVersion)
    let screen = NSScreen.main!
    let panel = ProbePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.takesKeyboard = !follow
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let stage = StageView(frame: NSRect(origin: .zero, size: screen.frame.size))
    stage.shareURL = fileURL(paths, image)
    stage.lowersForSharing = true
    panel.contentView = stage
    stage.show(display)
    panel.orderFrontRegardless()
    if !follow { panel.makeKey() }
    log("режим: \(follow ? "следовать (клавиатура у другого приложения)" : "свой список (клавиатура у панели)")")
    log("удерживайте ⌘ ~0,3 с — режим Live Text; Esc — выход" + (follow ? " (в --follow выход: ⌘ ⌥ Esc → завершить или Ctrl+C в терминале)" : ""))
    log("клавиши (только без --follow): Z — масштаб, R — поворот, H — подсветка, ⌘C — текст, ⌘L — поиск по изображению, ⌘S — поделиться, D — дерево оверлея")
    var analysis: ImageAnalysis?
    var analyzedTurns = -1
    func enterMode() {
        Task { @MainActor in
            if analysis == nil || analyzedTurns != stage.quarterTurns {
                analysis = await analyze(display, quarterTurns: stage.quarterTurns)
                analyzedTurns = stage.quarterTurns
                stage.overlay.analysis = analysis
            }
            if panel.level != .screenSaver { panel.level = .screenSaver; log("панель снова .screenSaver") }
            stage.isLiveMode = true
        }
    }
    // ⌘ в одиночку дольше 0,3 с. В --follow клавиатура не наша — опрашиваем состояние модификаторов.
    let hold = CommandHold()
    var timer: Timer?
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let command = flags.intersection(.deviceIndependentFlagsMask) == .command
        if command, hold.downAt == nil {
            hold.downAt = Date()
            hold.otherKey = false
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                if hold.downAt != nil, !hold.otherKey { enterMode() }
            }
        } else if !command, hold.downAt != nil {
            hold.downAt = nil
            timer?.invalidate()
            if stage.isLiveMode, !stage.isLatched { stage.isLiveMode = false }
        }
    }
    if follow {
        let quit = NSButton(title: "✕ Выход", target: nil, action: nil)
        quit.bezelStyle = .glass
        quit.frame = NSRect(x: 24, y: screen.frame.height - 64, width: 110, height: 32)
        quit.onAction = { exit(0) }
        stage.addSubview(quit)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { exit(0) }
        }
        var last: NSEvent.ModifierFlags = []
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            let now = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if now != last { last = now; modifiersChanged(now) }
        }
    } else {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            modifiersChanged(event.modifierFlags)
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            hold.otherKey = true
            let command = event.modifierFlags.contains(.command)
            switch (event.keyCode, command) {
            case (53, _): exit(0)
            case (6, false):  // Z
                stage.zoom = stage.zoom > 1 ? 1 : 2.5
                stage.offset = stage.zoom > 1 ? CGPoint(x: 300, y: -200) : .zero
                stage.relayout()
                log("масштаб \(stage.zoom)")
            case (15, false):  // R
                stage.quarterTurns = (stage.quarterTurns + 1) % 4
                stage.relayout()
                log("поворот \(stage.quarterTurns * 90)° — анализ заново при входе в режим ⌘")
            case (4, false):  // H
                stage.overlay.selectableItemsHighlighted.toggle()
            case (2, false):  // D
                stage.dumpOverlay()
            case (8, true):  // ⌘C
                let text = stage.overlay.selectedText
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                log("⌘C: скопировано «\(text.prefix(120))»")
            case (37, true):  // ⌘L
                if let button = stage.lookUpButton() {
                    stage.press(button)
                } else {
                    log("⌘L: кнопка поиска по изображению не найдена — нечего искать или другое устройство (D — дерево оверлея)")
                }
            case (1, true):  // ⌘S
                stage.share()
            default:
                return event
            }
            return nil
        }
    }
}

// Кнопка с замыканием — для «Выход».
extension NSButton {
    private static var actions: [ObjectIdentifier: () -> Void] = [:]
    var onAction: (() -> Void)? {
        get { Self.actions[ObjectIdentifier(self)] }
        set { Self.actions[ObjectIdentifier(self)] = newValue; target = self; action = #selector(runAction) }
    }
    @objc private func runAction() { onAction?() }
}

// MARK: - Запуск

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "measure" : args.removeFirst()
let follow = args.contains("--follow")
args.removeAll { $0 == "--follow" }
DispatchQueue.main.async {
    Task { @MainActor in
        switch command {
        case "measure": await measure(args); exit(0)
        case "align": await align(args)
        case "overlay": await overlayMode(args, follow: follow)
        case "sharetest": await shareTest(args)
        case "clicktest": await clickTest()
        case "cardtest": await cardTest()
        case "pilltest": await pillTest()
        case "classdump": await classDump(args)
        case "ddcheck":
            // Проверка сигнатуры, как в Ementium (DataDetectorBubbles): после загрузки VisionKit.
            let overlay = ImageAnalysisOverlayView()
            overlay.analysis = await analyze(surface(from: scaled(testImage(), maxSide: 1280)))
            let request = NSSelectorFromString("requestBubbleClosureUnanchorOnFailure:")
            guard let manager = ddManager(), let method = class_getInstanceMethod(type(of: manager), request) else { log("нет метода"); exit(1) }
            let arg = method_copyArgumentType(method, 2).map { defer { free($0) }; return String(cString: $0) } ?? "nil"
            let ret = method_copyReturnType(method)
            log("аргументов \(method_getNumberOfArguments(method)), тип аргумента «\(arg)», возврат «\(String(cString: ret))»")
            free(ret)
            exit(0)
        default: print("probe measure|align|overlay [файл] [--follow]"); exit(1)
        }
    }
}
app.run()
