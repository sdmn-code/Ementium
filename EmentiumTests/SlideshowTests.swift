import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Ementium

struct SlideshowClockTests {
    private let interval = Duration.seconds(4)

    private func running() -> SlideshowClock {
        var clock = SlideshowClock(interval: interval)
        _ = clock.toggle(imageOnScreen: true)
        return clock
    }

    @Test func startsCountingWhenImageIsOnScreen() {
        var clock = SlideshowClock(interval: interval)
        let outputs = clock.toggle(imageOnScreen: true)
        #expect(outputs == [.active(true), .keepDisplayAwake(true), .indicator(.play), .startTimer(interval)])
        #expect(clock.phase == .counting)
    }

    // Картинка ещё декодируется — отсчёт начнётся, когда она появится.
    @Test func waitsForImageBeforeCounting() {
        var clock = SlideshowClock(interval: interval)
        let outputs = clock.toggle(imageOnScreen: false)
        #expect(!outputs.contains(.startTimer(interval)))
        #expect(clock.phase == .waiting)
        let shown = clock.imageShown()
        #expect(shown == [.startTimer(interval)])
        #expect(clock.phase == .counting)
    }

    @Test func timerAdvancesAndWaitsForNextImage() {
        var clock = running()
        let fired = clock.timerFired()
        #expect(fired == [.advance])
        #expect(clock.phase == .waiting)
        // Повторный «тик» без картинки ничего не делает: шаг уже идёт.
        let again = clock.timerFired()
        #expect(again.isEmpty)
        let shown = clock.imageShown()
        #expect(shown == [.startTimer(interval)])
    }

    @Test func secondToggleStops() {
        var clock = running()
        let outputs = clock.toggle(imageOnScreen: true)
        #expect(outputs == [.cancelTimer, .keepDisplayAwake(false), .active(false), .indicator(.stop)])
        #expect(!clock.isActive)
    }

    @Test func pauseAndResume() {
        var clock = running()
        let paused = clock.pauseToggle()
        #expect(paused == [.cancelTimer, .indicator(.pause), .keepDisplayAwake(false)])
        // На паузе новая картинка (ручной шаг) отсчёт не запускает.
        let shown = clock.imageShown()
        #expect(shown.isEmpty)
        let manual = clock.manualStep()
        #expect(manual.isEmpty)
        let resumed = clock.pauseToggle()
        #expect(resumed == [.indicator(.play), .keepDisplayAwake(true), .startTimer(interval)])
        #expect(clock.phase == .counting)
    }

    @Test func pauseOutsideSlideshowDoesNothing() {
        var clock = SlideshowClock(interval: interval)
        let outputs = clock.pauseToggle()
        #expect(outputs.isEmpty)
        #expect(!clock.isActive)
    }

    // Ручной шаг — отсчёт заново сразу (стрелка на краю никуда не ведёт — показ не должен встать).
    @Test func manualStepRestartsCountdown() {
        var clock = running()
        let manual = clock.manualStep()
        #expect(manual == [.startTimer(interval)])
        #expect(clock.phase == .counting)
    }

    // Перешли на картинку, которая ещё декодируется (большой RAW): ждём её, а не шагаем дальше по таймеру.
    @Test func manualStepToPendingImageWaitsForIt() {
        var clock = running()
        let manual = clock.manualStep(imagePending: true)
        #expect(manual == [.cancelTimer])
        #expect(clock.phase == .waiting)
        let fired = clock.timerFired()
        #expect(fired.isEmpty)
        let shown = clock.imageShown()
        #expect(shown == [.startTimer(interval)])
    }

    // Шаг слайд-шоу ещё ждёт картинку, а пользователь нажал стрелку на краю — отсчёт заново, не вечное ожидание.
    @Test func manualStepWhileWaitingRestartsCountdown() {
        var clock = running()
        _ = clock.timerFired()
        let manual = clock.manualStep()
        #expect(manual == [.startTimer(interval)])
        #expect(clock.phase == .counting)
    }

    @Test func endWithoutLoopStopsWithMessage() {
        var clock = running()
        _ = clock.timerFired()
        let end = clock.reachedEnd()
        #expect(end == [.cancelTimer, .keepDisplayAwake(false), .active(false), .indicator(.stop), .message(.finished)])
        #expect(!clock.isActive)
    }

    @Test func failedAdvanceRetriesSoon() {
        var clock = running()
        _ = clock.timerFired()
        let retry = clock.advanceFailed()
        #expect(retry == [.startTimer(SlideshowClock.retryDelay)])
        #expect(clock.phase == .counting)
    }

    @Test func blockedMessageIsRateLimited() {
        var clock = running()
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let first = clock.blocked(at: start)
        #expect(first == [.message(.blocked)])
        let soon = clock.blocked(at: start.addingTimeInterval(1))
        #expect(soon.isEmpty)
        let later = clock.blocked(at: start.addingTimeInterval(2.1))
        #expect(later == [.message(.blocked)])
    }

    @Test func blockedOutsideSlideshowIsSilent() {
        var clock = SlideshowClock(interval: interval)
        let outputs = clock.blocked(at: Date())
        #expect(outputs.isEmpty)
    }

    // Закрытие просмотра: всё выключить, в том числе запрет сна, — без плашки.
    @Test func resetTurnsEverythingOff() {
        var clock = running()
        _ = clock.pauseToggle()
        let outputs = clock.reset()
        #expect(outputs == [.cancelTimer, .keepDisplayAwake(false), .active(false), .indicator(.hidden)])
        let again = clock.reset()
        #expect(again.isEmpty)
    }
}

struct SlideshowKeyTests {
    private func key(_ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = [],
                     repeat isRepeat: Bool = false) -> SlideshowKey {
        SlideshowKey.resolve(
            ViewerCommand(keyCode: keyCode, characters: characters, modifiers: modifiers), keyCode: keyCode,
            hasModifiers: !modifiers.intersection([.command, .option, .control, .shift]).isEmpty, isRepeat: isRepeat
        )
    }

    @Test func sTogglesInAnyLayout() {
        #expect(ViewerCommand(keyCode: 1, characters: "s", modifiers: []) == .slideshow)
        #expect(ViewerCommand(keyCode: 1, characters: "ы", modifiers: []) == .slideshow)
        #expect(ViewerCommand(keyCode: 1, characters: "s", modifiers: .capsLock) == .slideshow)
        #expect(ViewerCommand(keyCode: 1, characters: "s", modifiers: .command) == .share)
        #expect(ViewerCommand(keyCode: 1, characters: "S", modifiers: .shift) == nil)
        #expect(ViewerCommand(keyCode: 1, characters: "ß", modifiers: .option) == nil)
        #expect(key(1, "s") == .toggle)
        #expect(key(1, "s", repeat: true) == .ignore)
    }

    // Пробел — пауза, а не закрытие, при любой настройке; `Esc` — выход из слайд-шоу, как `S`.
    @Test func spacePausesEscExitsSlideshow() {
        #expect(key(49, " ") == .pause)
        #expect(key(49, " ", repeat: true) == .ignore)
        #expect(key(53) == .toggle)
        #expect(key(53, repeat: true) == .ignore)
    }

    @Test func arrowsNavigateEvenWhenHeld() {
        #expect(key(124) == .navigate(.next))
        #expect(key(123) == .navigate(.previous))
        #expect(key(125, repeat: true) == .navigate(.next))
    }

    @Test func otherCommandsAreBlocked() {
        #expect(key(18, "1") == .blocked)                 // метка
        #expect(key(51, nil, .command) == .blocked)       // ⌘⌫
        #expect(key(6, "z", .command) == .blocked)        // ⌘Z
        #expect(key(24, "=") == .blocked)                 // масштаб
        #expect(key(124, nil, .command) == .blocked)      // поворот
        #expect(key(1, "s", .command) == .blocked)        // ⌘S
        #expect(key(12, "q", .command) == .blocked)       // ⌘Q
        #expect(key(115) == .blocked)                     // Home
        #expect(key(18, "1", repeat: true) == .ignore)   // зажатая — без плашки
        #expect(key(0, "a") == .ignore)                   // не наша клавиша
    }
}

struct SlideshowFollowingTests {
    private func action(_ keyCode: UInt16, _ flags: CGEventFlags = [], characters: String? = nil,
                        repeat isRepeat: Bool = false, slideshow: Bool = true) -> ViewerKeyAction {
        InterceptionPolicy.followingAction(
            keyCode: keyCode, characters: characters, flags: flags, isRepeat: isRepeat, systemShortcuts: [],
            spaceClosesViewer: true, trashEnabled: true, tagsEnabled: true, slideshow: slideshow
        )
    }

    @Test func sTogglesOutsideAndInside() {
        #expect(action(1, characters: "s", slideshow: false) == .slideshow)
        #expect(action(1, characters: "s") == .slideshow)
        #expect(action(1, characters: "s", repeat: true) == .swallow)
        #expect(action(1, .maskCommand, characters: "s", slideshow: false) == .share)
    }

    @Test func spacePausesInsteadOfClosing() {
        #expect(action(49, slideshow: false) == .close)
        #expect(action(49) == .slideshowPause)
        #expect(action(49, repeat: true) == .swallow)
        #expect(action(53) == .slideshow)                                     // Esc — выход из слайд-шоу
        #expect(action(53, slideshow: false) == .close)
    }

    @Test func arrowsStillStep() {
        #expect(action(124) == .step(.right))
        #expect(action(125, repeat: true) == .step(.down))
    }

    @Test func ourCommandsAreBlocked() {
        #expect(action(18) == .slideshowBlocked)                              // метка
        #expect(action(51, .maskCommand) == .slideshowBlocked)                // ⌘⌫
        #expect(action(6, .maskCommand, characters: "z") == .slideshowBlocked)
        #expect(action(24) == .slideshowBlocked)                              // масштаб
        #expect(action(115) == .slideshowBlocked)                             // Home
        #expect(action(43, .maskCommand) == .slideshowBlocked)                // ⌘,
        #expect(action(12, .maskCommand, characters: "q") == .slideshowBlocked)
        #expect(action(18, repeat: true) == .swallow)
        #expect(action(0, characters: "a") == .swallow)
    }

    // Системные сочетания — как всегда: просмотр закрывается, Spotlight и ⌘Tab работают.
    @Test func systemShortcutsStillPass() {
        #expect(action(48, .maskCommand) == .passAndClose)                    // ⌘Tab
        #expect(action(49, .maskCommand) == .passAndClose)                    // ⌘Пробел
        #expect(action(122) == .passAndClose)                                 // F1
    }
}
