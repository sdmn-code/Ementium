import AppKit
import Testing
@testable import Ementium

struct ViewerCommandTests {
    private func command(_ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> ViewerCommand? {
        ViewerCommand(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    @Test(arguments: [
        (UInt16(124), ViewerCommand.next), (125, .next),
        (123, .previous), (126, .previous),
        (53, .close), (49, .close),
    ])
    func plainKeys(keyCode: UInt16, expected: ViewerCommand) {
        #expect(command(keyCode) == expected)
    }

    // AppKit помечает стрелки флагами .function и .numericPad, а Caps Lock может быть включён — это не должно мешать.
    @Test func arrowsIgnoreFunctionNumericPadAndCapsLock() {
        #expect(command(124, nil, [.function, .numericPad]) == .next)
        #expect(command(123, nil, .capsLock) == .previous)
    }

    @Test func commandQQuitsInAnyLayout() {
        #expect(command(12, "q", .command) == .quit)  // QWERTY
        #expect(command(12, "й", .command) == .quit)  // русская раскладка: символ не латинский, выручает физический код
        #expect(command(0, "q", .command) == .quit)   // AZERTY: Q на месте A
        #expect(command(12, "a", .command) == nil)    // AZERTY: на месте Q буква A — это не выход
    }

    @Test(arguments: [
        (UInt16(12), String?("q"), NSEvent.ModifierFlags()),  // Q без ⌘
        (49, " ", .shift),                           // ⇧Пробел
        (53, nil, .option),                          // ⌥Esc
        (124, nil, NSEvent.ModifierFlags([.command, .shift])),  // ⇧⌘→ (⌘→ — поворот)
        (0, "a", NSEvent.ModifierFlags()),           // A
    ])
    func otherKeysAreIgnored(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) {
        #expect(command(keyCode, characters, modifiers) == nil)
    }
}

struct ViewerZoomKeyTests {
    private func command(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> ViewerCommand? {
        ViewerCommand(keyCode: keyCode, characters: nil, modifiers: modifiers)
    }

    @Test func plusMinusZeroZoom() {
        #expect(command(24) == .zoomIn)                    // =
        #expect(command(24, .shift) == .zoomIn)            // + (⇧=)
        #expect(command(27) == .zoomOut)                   // -
        #expect(command(29) == .zoomFit)                   // 0
    }

    @Test func keypadAndCommandVariantsZoom() {
        #expect(command(69, .numericPad) == .zoomIn)       // + на цифровом блоке
        #expect(command(78, .numericPad) == .zoomOut)
        #expect(command(82, .numericPad) == .zoomFit)
        #expect(command(24, .command) == .zoomIn)          // ⌘+ как в Просмотре
        #expect(command(24, [.command, .shift]) == .zoomIn)
        #expect(command(27, .command) == .zoomOut)
        #expect(command(29, .command) == .zoomFit)
    }

    // ⌘, — настройки; в русской раскладке это ⌘Б, та же физическая клавиша.
    @Test func commandCommaOpensSettings() {
        #expect(command(43, .command) == .openSettings)
        #expect(command(43) == nil)
    }

    @Test func otherModifiersDoNotZoom() {
        #expect(command(24, .option) == nil)
        #expect(command(27, .control) == nil)
    }
}

struct FittedRectTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func smallImageIsNotUpscaledAndIsCentered() {
        let rect = ViewerView.fittedRect(imageSize: CGSize(width: 64, height: 64), in: screen)
        #expect(rect == CGRect(x: 688, y: 418, width: 64, height: 64))
    }

    @Test func wideImageFitsWidth() {
        let rect = ViewerView.fittedRect(imageSize: CGSize(width: 2880, height: 900), in: screen)
        #expect(rect == CGRect(x: 0, y: 225, width: 1440, height: 450))
    }

    @Test func tallImageFitsHeight() {
        let rect = ViewerView.fittedRect(imageSize: CGSize(width: 1000, height: 1800), in: screen)
        #expect(rect == CGRect(x: 470, y: 0, width: 500, height: 900))
    }

    @Test func emptySizeGivesEmptyRect() {
        #expect(ViewerView.fittedRect(imageSize: .zero, in: screen) == .zero)
    }

    // SVG-иконка 24×24 вписывается в экран, как в Quick Look, — при любой настройке «Увеличивать маленькие».
    @Test func vectorIsScaledToTheScreen() {
        let size = ViewerView.vectorSize(CGSize(width: 24, height: 24), in: screen.size)
        #expect(size == CGSize(width: 900, height: 900))
        let zoom = ZoomModel(imageSize: size, viewSize: screen.size, fitFraction: 0.95)
        #expect(zoom.imageRect.height == 855)
        #expect(zoom.isFit)
    }

    @Test func wideVectorIsScaledByWidth() {
        #expect(ViewerView.vectorSize(CGSize(width: 2880, height: 900), in: screen.size) == CGSize(width: 1440, height: 450))
    }
}
