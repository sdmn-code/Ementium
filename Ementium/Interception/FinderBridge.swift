import AppKit
import ApplicationServices
import os

/// Следит за фокусом и выделением Finder через Accessibility и держит актуальный снимок
/// в `InterceptionState`. Устройство AX у Finder выяснено прототипом `Prototypes/FinderAXProbe`.
///
/// Всё, кроме `start` / `reattach` / `refreshSoon`, выполняется на собственном потоке:
/// AX-запросы к занятому Finder длятся до сотен миллисекунд и не должны блокировать ни
/// главный поток, ни перехват клавиш.
nonisolated final class FinderBridge: @unchecked Sendable {
    static let finderBundleID = "com.apple.finder"

    private let state: InterceptionState
    private let thread = RunLoopThread(name: "Ementium.FinderBridge")
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "finder")

    // Только на потоке моста.
    private var observer: AXObserver?
    private var finderApp: AXUIElement?
    private var debounce: Timer?
    /// Элемент вида с выделением (список, коллекция, колонка) — из него берётся список виртуального окна.
    private var viewElement: AXUIElement?

    /// После последнего уведомления ждём, пока выделение перестанет меняться (зажатая стрелка).
    private static let debounceInterval = 0.05

    private static let notifications = [
        kAXFocusedUIElementChangedNotification,
        kAXSelectedRowsChangedNotification,
        kAXSelectedChildrenChangedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    init(state: InterceptionState) {
        self.state = state
    }

    func start() {
        thread.perform { self.attach() }
    }

    /// Finder перезапустился — у него новый pid, старая подписка мертва.
    func reattach() {
        thread.perform { self.attach() }
    }

    /// Finder стал активным: уведомления о фокусе приходят не всегда, обновим снимок сами.
    func refreshSoon() {
        state.update { $0.isFinderStateStale = true }
        thread.perform { self.scheduleRefresh() }
    }

    /// Файлы, показанные в текущем виде Finder, в порядке окна. В «списке» и «колонках» — все,
    /// в «значках» и «галерее» — только подгруженные рядом с экраном (Finder создаёт AX-элементы лениво).
    /// Это сотни AX-запросов (~0,9 мс на элемент), поэтому только по запросу и на потоке моста.
    func viewItems() async -> [URL] {
        await withCheckedContinuation { continuation in
            thread.perform { continuation.resume(returning: self.enumerateView()) }
        }
    }

    // MARK: - Поток моста

    private func attach() {
        detach()
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first else {
            log.info("Finder не запущен")
            return
        }
        let pid = finder.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        // Подвисший Finder не должен держать поток моста дольше секунды.
        AXUIElementSetMessagingTimeout(app, 1.0)

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FinderBridge>.fromOpaque(refcon).takeUnretainedValue().scheduleRefresh()
        }
        var created: AXObserver?
        let error = AXObserverCreate(pid, callback, &created)
        guard error == .success, let created else {
            log.error("AXObserverCreate: \(error.rawValue)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            let result = AXObserverAddNotification(created, app, name as CFString, refcon)
            if result != .success {
                log.error("Подписка \(name): \(result.rawValue)")
            }
        }
        thread.add(AXObserverGetRunLoopSource(created))
        observer = created
        finderApp = app
        log.info("Подписка на Finder (pid \(pid))")
        refresh()
    }

    private func detach() {
        debounce?.invalidate()
        debounce = nil
        if let observer {
            thread.remove(AXObserverGetRunLoopSource(observer))
        }
        observer = nil
        finderApp = nil
        viewElement = nil
        state.update { $0.isFinderStateStale = true }
    }

    private func scheduleRefresh() {
        state.update { $0.isFinderStateStale = true }
        debounce?.invalidate()
        let timer = Timer(timeInterval: Self.debounceInterval, repeats: false) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(timer, forMode: .default)
        debounce = timer
    }

    private func refresh() {
        guard let finderApp else { return }
        guard let focused = element(attribute(finderApp, kAXFocusedUIElementAttribute)) else {
            // Нет фокуса (нет окон) — выделения тоже нет.
            viewElement = nil
            publish(isTextField: false, selection: [], isVirtual: false)
            return
        }
        if isEditableText(focused) {
            publish(isTextField: true, selection: [], isVirtual: false)
            return
        }
        let items = elements(attribute(focused, kAXSelectedRowsAttribute))
            ?? elements(attribute(focused, kAXSelectedChildrenAttribute))
            ?? []
        let selection = items.compactMap { findURL($0, depth: 2) }
        viewElement = focused
        publish(isTextField: false, selection: selection, isVirtual: isVirtualWindow(of: focused, selection: selection))
    }

    /// Виртуальность важна только для одного выделенного файла: несколько файлов листаются сами по себе.
    private func isVirtualWindow(of view: AXUIElement, selection: [URL]) -> Bool {
        guard selection.count == 1,
              let window = element(attribute(view, kAXWindowAttribute)),
              let title = attribute(window, kAXTitleAttribute) as? String else { return false }
        let folder = selection[0].deletingLastPathComponent().path
        return !FinderLocation.isFolderWindow(title: title, folderName: FileManager.default.displayName(atPath: folder))
    }

    private func publish(isTextField: Bool, selection: [URL], isVirtual: Bool) {
        let hasImage = selection.contains(where: ImageDirectory.isImage)
        state.update {
            $0.isTextFieldFocused = isTextField
            $0.selection = selection
            $0.selectionHasImage = hasImage
            $0.isVirtualLocation = isVirtual
            $0.isFinderStateStale = false
        }
    }

    private func enumerateView() -> [URL] {
        guard let viewElement else { return [] }
        let items: [AXUIElement]
        if let rows = elements(attribute(viewElement, kAXRowsAttribute)) {
            items = rows
        } else {
            // Значки и галерея: элементы лежат внутри секций (AXList); колонка — сразу дети.
            items = (elements(attribute(viewElement, kAXChildrenAttribute)) ?? []).flatMap { child in
                attribute(child, kAXRoleAttribute) as? String == kAXListRole
                    ? elements(attribute(child, kAXChildrenAttribute)) ?? []
                    : [child]
            }
        }
        return items.compactMap { findURL($0, depth: 2) }
    }

    // MARK: - AX

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func element(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elements(_ value: AnyObject?) -> [AXUIElement]? {
        guard let array = value as? [AXUIElement], !array.isEmpty else { return nil }
        return array
    }

    /// Поле переименования, строка поиска, «Переход к папке»: роль текстового поля и изменяемое значение.
    private func isEditableText(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Путь к файлу лежит в `AXURL` у элемента выделения или его потомка: в значках и галерее —
    /// у картинки внутри группы, в списке — у текстового поля внутри ячейки строки.
    private func findURL(_ element: AXUIElement, depth: Int) -> URL? {
        if let url = attribute(element, kAXURLAttribute) as? URL, url.isFileURL {
            return url
        }
        guard depth > 0, let children = elements(attribute(element, kAXChildrenAttribute)) else { return nil }
        for child in children {
            if let url = findURL(child, depth: depth - 1) { return url }
        }
        return nil
    }
}
