import CoreGraphics
import ImageIO
import Testing
@testable import Ementium

struct LiveTextHoldTests {
    @Test func holdingCommandAloneEntersAfterDelay() {
        var tracker = LiveTextHoldTracker()
        let pressed = tracker.modifiersChanged(.command)
        #expect(pressed == [.startTimer])
        let fired = tracker.timerFired()
        #expect(fired == [.enter])
        #expect(tracker.isActive)
        let released = tracker.modifiersChanged([])
        #expect(released == [.exit])
        #expect(!tracker.isActive)
    }

    // ⌘C, ⌘→, ⌘⌫ — сочетания: режим не мигает и не распознаёт впустую.
    @Test func shortcutDuringArmingCancels() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.modifiersChanged(.command)
        let key = tracker.keyPressed()
        #expect(key == [.cancelTimer])
        let fired = tracker.timerFired()
        #expect(fired == [])
        let released = tracker.modifiersChanged([])
        #expect(released == [])
        // Следующее удержание — снова режим.
        let again = tracker.modifiersChanged(.command)
        #expect(again == [.startTimer])
    }

    @Test func commandWithOtherModifierIsNotHold() {
        var tracker = LiveTextHoldTracker()
        let combo = tracker.modifiersChanged([.command, .shift])
        #expect(combo == [])
        let onlyCommandLeft = tracker.modifiersChanged(.command)
        #expect(onlyCommandLeft == [])  // ⇧ отпустили, ⌘ ещё держат — это было сочетание
        _ = tracker.modifiersChanged([])
        let fresh = tracker.modifiersChanged(.command)
        #expect(fresh == [.startTimer])
    }

    @Test func addingModifierWhileArmingCancels() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.modifiersChanged(.command)
        let combo = tracker.modifiersChanged([.command, .option])
        #expect(combo == [.cancelTimer])
        #expect(tracker.state == .cancelled)
    }

    // В режиме ⌘C, ⌘L, ⌘S его не снимают.
    @Test func keysInModeKeepIt() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.modifiersChanged(.command)
        _ = tracker.timerFired()
        let key = tracker.keyPressed()
        #expect(key == [])
        #expect(tracker.isActive)
    }

    // Кнопка Live Text: ⌘ можно отпустить; повторное нажатие снимает.
    @Test func latchKeepsModeWithoutCommand() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.modifiersChanged(.command)
        _ = tracker.timerFired()
        let latched = tracker.setLatched(true, commandHeld: true)
        #expect(latched == [])
        let released = tracker.modifiersChanged([])
        #expect(released == [])
        #expect(tracker.isActive)
        let unlatched = tracker.setLatched(false, commandHeld: false)
        #expect(unlatched == [.exit])
        #expect(!tracker.isActive)
    }

    @Test func unlatchWhileHoldingCommandStaysUntilRelease() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.modifiersChanged(.command)
        _ = tracker.timerFired()
        _ = tracker.setLatched(true, commandHeld: true)
        let unlatched = tracker.setLatched(false, commandHeld: true)
        #expect(unlatched == [])
        let released = tracker.modifiersChanged([])
        #expect(released == [.exit])
    }

    // Зафиксированный режим снимает новое нажатие ⌘ — и до отпускания режим снова не включается.
    @Test func newCommandPressExitsLatchedMode() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.modifiersChanged(.command)
        _ = tracker.timerFired()
        _ = tracker.setLatched(true, commandHeld: true)
        let released = tracker.modifiersChanged([])
        #expect(released == [])
        let pressed = tracker.modifiersChanged(.command)
        #expect(pressed == [.exit])
        #expect(!tracker.isLatched)
        let held = tracker.timerFired()
        #expect(held == [])
        let releasedAgain = tracker.modifiersChanged([])
        #expect(releasedAgain == [])
        #expect(tracker.state == .idle)
    }

    // ⌘L: режим сразу и зафиксирован.
    @Test func lookUpLatchEntersImmediately() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.modifiersChanged(.command)
        let latched = tracker.latch()
        #expect(latched == [.cancelTimer, .enter])
        let released = tracker.modifiersChanged([])
        #expect(released == [])
        #expect(tracker.isActive)
        let again = tracker.latch()
        #expect(again == [])
        let pressed = tracker.modifiersChanged(.command)
        #expect(pressed == [.exit])
    }

    // Смена картинки, закрытие.
    @Test func resetExitsAndForgetsLatch() {
        var tracker = LiveTextHoldTracker()
        _ = tracker.latch()
        let reset = tracker.reset()
        #expect(reset == [.exit])
        #expect(!tracker.isLatched)
        var arming = LiveTextHoldTracker()
        _ = arming.modifiersChanged(.command)
        let cancelled = arming.reset()
        #expect(cancelled == [.cancelTimer])
    }

    @Test func orientationFollowsRotation() {
        #expect(LiveTextAnalyzer.orientation(quarterTurns: 0) == .up)
        #expect(LiveTextAnalyzer.orientation(quarterTurns: 1) == .right)
        #expect(LiveTextAnalyzer.orientation(quarterTurns: 2) == .down)
        #expect(LiveTextAnalyzer.orientation(quarterTurns: -1) == .left)
        #expect(LiveTextAnalyzer.orientation(quarterTurns: 5) == .right)
    }
}

struct LiveTextGeometryTests {
    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    // Поворот по часовой: левый верхний угол уходит в правый верхний, как у `imageLayer`.
    @Test func rotatingUnitPointMatchesLayer() {
        #expect(ViewerView.rotateUnit(CGPoint(x: 0, y: 0), quarterTurns: 1) == CGPoint(x: 1, y: 0))
        #expect(ViewerView.rotateUnit(CGPoint(x: 1, y: 0), quarterTurns: 1) == CGPoint(x: 1, y: 1))
        #expect(ViewerView.rotateUnit(CGPoint(x: 0, y: 1), quarterTurns: 1) == CGPoint(x: 0, y: 0))
        #expect(ViewerView.rotateUnit(CGPoint(x: 0.25, y: 0.5), quarterTurns: 2) == CGPoint(x: 0.75, y: 0.5))
        #expect(ViewerView.rotateUnit(CGPoint(x: 0, y: 0), quarterTurns: -1) == CGPoint(x: 0, y: 1))
    }

    // Левая верхняя четверть картинки — левая верхняя четверть её прямоугольника на экране (ось y — вверх).
    @Test func cropToScreenWithoutRotation() {
        let rect = CGRect(x: 100, y: 50, width: 400, height: 200)
        let screen = ViewerView.screenRect(ofUnit: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: rect, quarterTurns: 0)
        #expect(close(screen, CGRect(x: 100, y: 150, width: 200, height: 100)))
    }

    // Повёрнутая на 90°: левая верхняя четверть картинки — правая верхняя на экране.
    @Test func cropToScreenRotated() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 400)
        let screen = ViewerView.screenRect(ofUnit: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), in: rect, quarterTurns: 1)
        #expect(close(screen, CGRect(x: 100, y: 200, width: 100, height: 200)))
    }

    @Test func screenAndUnitRoundTrip() {
        let rect = CGRect(x: -300, y: -120, width: 2400, height: 1600)
        let crop = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.45)
        for turns in -1...4 {
            let screen = ViewerView.screenRect(ofUnit: crop, in: rect, quarterTurns: turns)
            let back = ViewerView.unitRect(ofScreen: screen, in: rect, quarterTurns: turns)
            #expect(close(back, crop), "поворот \(turns)")
        }
    }

    // Почти всё видно — распознаём целиком; увеличили — видимую часть с запасом.
    @Test func cropFollowsVisiblePart() {
        #expect(ViewerWindowController.liveCrop(for: nil) == ViewerView.unitRect)
        #expect(ViewerWindowController.liveCrop(for: CGRect(x: 0, y: 0, width: 1, height: 0.9)) == ViewerView.unitRect)
        let crop = ViewerWindowController.liveCrop(for: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        #expect(close(crop, CGRect(x: 0.38, y: 0.38, width: 0.24, height: 0.24)))
        let edge = ViewerWindowController.liveCrop(for: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        #expect(edge.minX == 0 && edge.minY == 0)
    }

    @Test func recognizedCropIsReusedUntilZoomedMuchFurther() {
        let recognized = ViewerWindowController.liveCrop(for: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        // Чуть сдвинули, видимое ещё внутри распознанного.
        #expect(ViewerWindowController.liveCropCovers(recognized, visible: CGRect(x: 0.41, y: 0.4, width: 0.19, height: 0.2)))
        // Ушли за край распознанного.
        #expect(!ViewerWindowController.liveCropCovers(recognized, visible: CGRect(x: 0.6, y: 0.4, width: 0.2, height: 0.2)))
        // Увеличили втрое — мелкий текст распознается лучше.
        #expect(!ViewerWindowController.liveCropCovers(recognized, visible: CGRect(x: 0.47, y: 0.47, width: 0.066, height: 0.066)))
        // Картинка целиком годится, пока видно почти всю.
        #expect(ViewerWindowController.liveCropCovers(ViewerView.unitRect, visible: nil))
    }
}
