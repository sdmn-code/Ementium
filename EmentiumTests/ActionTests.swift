import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Ementium

struct NewKeysTests {
    private func command(_ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> ViewerCommand? {
        ViewerCommand(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    @Test func ownListCommands() {
        #expect(command(115) == .first)                                  // Home
        #expect(command(119, nil, [.function]) == .last)                 // fn → на MacBook = End
        #expect(command(124, nil, [.command, .function, .numericPad]) == .rotateClockwise)
        #expect(command(123, nil, .command) == .rotateCounterclockwise)
        #expect(command(15, "r", .command) == .rotateClockwise)          // ⌘R
        #expect(command(37, "l", .command) == .rotateCounterclockwise)   // ⌘L
        #expect(command(15, "к", .command) == .rotateClockwise)          // русская раскладка — по физической клавише
        #expect(command(8, "c", .command) == .copy)
        #expect(command(8, "с", .command) == .copy)                      // кириллическая «с»
        #expect(command(31, "o", .command) == .openInApp)
        #expect(command(124, nil, [.command, .shift]) == nil)            // ⇧⌘→ — не наше
    }

    private func action(_ keyCode: UInt16, _ characters: String?, _ flags: CGEventFlags, repeat isRepeat: Bool = false) -> ViewerKeyAction {
        InterceptionPolicy.followingAction(
            keyCode: keyCode, characters: characters, flags: flags, isRepeat: isRepeat, systemShortcuts: []
        )
    }

    @Test func followingModeActions() {
        #expect(action(115, nil, []) == .edge(first: true))
        #expect(action(119, nil, .maskSecondaryFn) == .edge(first: false))
        #expect(action(124, nil, .maskCommand) == .rotate(clockwise: true))
        #expect(action(123, nil, .maskCommand) == .rotate(clockwise: false))
        #expect(action(8, "c", .maskCommand) == .copy)
        #expect(action(31, "o", .maskCommand) == .openInApp)
        // Обычные стрелки по-прежнему листают.
        #expect(action(124, nil, []) == .step(.right))
    }

    // Зажатое сочетание срабатывает один раз.
    @Test func autorepeatDoesNotRepeatActions() {
        #expect(action(124, nil, .maskCommand, repeat: true) == .swallow)
        #expect(action(8, "c", .maskCommand, repeat: true) == .swallow)
        #expect(action(31, "o", .maskCommand, repeat: true) == .swallow)
    }

    // Пользователь сам назначил ⌘→ в системных настройках — перехват пропускает.
    @Test func userSystemShortcutWins() {
        let shortcut = SystemShortcut(keyCode: 124, modifiers: .maskCommand, action: .pass)
        let result = InterceptionPolicy.followingAction(
            keyCode: 124, characters: nil, flags: .maskCommand, isRepeat: false, systemShortcuts: [shortcut]
        )
        #expect(result == .pass)
    }
}

struct RotationTests {
    private let screen = CGSize(width: 1000, height: 800)

    @Test func rotationSwapsSidesAndFits() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        zoom.zoomIn()
        zoom.rotate(clockwise: true)
        #expect(zoom.quarterTurns == 1)
        #expect(zoom.imageSize == CGSize(width: 2000, height: 4000))
        #expect(zoom.isFit)
        #expect(zoom.imageRect.height == 800)  // вертикальная теперь вписывается по высоте
        #expect(zoom.offset == .zero)
    }

    @Test func fourTurnsReturnToStart() {
        var zoom = ZoomModel(imageSize: CGSize(width: 300, height: 200), viewSize: screen)
        for _ in 0..<4 { zoom.rotate(clockwise: true) }
        #expect(zoom.quarterTurns == 0)
        zoom.rotate(clockwise: false)
        #expect(zoom.quarterTurns == 3)
        #expect(zoom.imageSize == CGSize(width: 200, height: 300))
    }

    @Test func nextImageIsNotRotated() {
        var zoom = ZoomModel(imageSize: CGSize(width: 300, height: 200), viewSize: screen)
        zoom.rotate(clockwise: true)
        zoom.replaceImage(size: CGSize(width: 500, height: 400))
        #expect(zoom.quarterTurns == 0)
        #expect(zoom.imageSize == CGSize(width: 500, height: 400))
    }

    // Поворот запоминается вместе с масштабом, даже во «вписать».
    @Test func rotationIsRemembered() {
        let url = URL(fileURLWithPath: "/tmp/r.jpg")
        var memory = ZoomMemory()
        var zoom = ZoomModel(imageSize: CGSize(width: 300, height: 200), viewSize: screen)
        zoom.rotate(clockwise: false)
        memory.remember(zoom, for: url)
        #expect(memory.placement(for: url) == .restore(scale: zoom.scale, offset: .zero, quarterTurns: 3))

        var restored = ZoomModel(imageSize: CGSize(width: 300, height: 200), viewSize: screen)
        restored.restore(scale: zoom.scale, offset: .zero, quarterTurns: 3)
        #expect(restored.imageSize == CGSize(width: 200, height: 300))
    }
}

struct EdgeTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    private let isImage: (URL) -> Bool = { $0.pathExtension == "png" }

    @Test func edgesSkipDocumentsAndHeaders() {
        let items: [URL?] = [nil, url("a.txt"), url("b.png"), url("c.png"), url("d.txt"), nil]
        #expect(EdgeTarget.find(count: items.count, url: { items[$0] }, isImage: isImage, first: true) == url("b.png"))
        #expect(EdgeTarget.find(count: items.count, url: { items[$0] }, isImage: isImage, first: false) == url("c.png"))
    }

    @Test func noImages() {
        let items: [URL?] = [url("a.txt")]
        #expect(EdgeTarget.find(count: 1, url: { items[$0] }, isImage: isImage, first: true) == nil)
    }
}
