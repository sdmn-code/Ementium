import CoreGraphics
import Foundation
import Testing
@testable import Ementium

struct SwipeTrackerTests {
    /// Пальцы двигаются равномерно: `steps` шагов по `dx` с интервалом `interval`.
    private func swipe(
        _ dx: CGFloat, steps: Int, interval: TimeInterval = 1.0 / 60, dy: CGFloat = 0,
        canGoNext: Bool = true, canGoPrevious: Bool = true
    ) -> (tracker: SwipeTracker, end: TimeInterval) {
        var tracker = SwipeTracker(width: 1000, canGoNext: canGoNext, canGoPrevious: canGoPrevious)
        var time: TimeInterval = 0
        for _ in 0..<steps {
            time += interval
            tracker.move(dx: dx, dy: dy, time: time)
        }
        return (tracker, time)
    }

    // Протянули влево на треть ширины — следующая (как в Фото).
    @Test func longSlowSwipeLeftGoesNext() {
        let (tracker, end) = swipe(-10, steps: 35, interval: 0.05)  // 350 пт за 1,75 с — медленно
        #expect(tracker.isTracking)
        #expect(tracker.offset == -350)
        #expect(tracker.end(time: end) == .next)
    }

    @Test func swipeRightGoesPrevious() {
        let (tracker, end) = swipe(10, steps: 30, interval: 0.05)
        #expect(tracker.end(time: end) == .previous)
    }

    // Ускоренная прокрутка: путь в несколько экранов, а картинка сдвигается не дальше ширины.
    @Test func offsetStopsAtWidth() {
        let (tracker, end) = swipe(-100, steps: 30)  // 3000 пт при ширине 1000
        #expect(tracker.offset == -1000)
        #expect(tracker.end(time: end) == .next)
    }

    // Не дотянули до порога расстояния (20 пт), но взмахнули быстро — листает; так же медленно — нет.
    @Test func flickBelowDistanceTurns() {
        let (fast, fastEnd) = swipe(-4, steps: 4)  // 16 пт за 0,05 с — 320 пт/с
        #expect(fast.end(time: fastEnd) == .next)
        let (slow, slowEnd) = swipe(-4, steps: 4, interval: 0.1)  // 16 пт, 40 пт/с
        #expect(slow.end(time: slowEnd) == .cancel)
    }

    // Короткий, но быстрый взмах — листает.
    @Test func quickFlickGoesNext() {
        let (tracker, end) = swipe(-2.5, steps: 5)  // 12,5 пт за 4/60 с ≈ 190 пт/с — мало
        #expect(tracker.end(time: end) == .cancel)
        let (fast, fastEnd) = swipe(-6, steps: 5)  // 30 пт, ~450 пт/с — теперь достаточно
        #expect(fast.end(time: fastEnd) == .next)
    }

    // Недотянули медленно — вернуть.
    @Test func shortSlowSwipeCancels() {
        let (tracker, end) = swipe(-0.5, steps: 20, interval: 0.05)  // 10 пт (< 2 % ширины) медленно
        #expect(tracker.end(time: end) == .cancel)
    }

    // На краю картинка тянется туго и возвращается.
    @Test func edgeResistsAndCancels() {
        let (tracker, end) = swipe(-20, steps: 30, canGoNext: false)
        #expect(tracker.offset == -600 * SwipeTracker.edgeResistance)
        #expect(tracker.end(time: end) == .cancel)
    }

    // Вертикальная прокрутка — не смахивание.
    @Test func verticalScrollIsIgnored() {
        let (tracker, end) = swipe(1, steps: 30, dy: 10)
        #expect(!tracker.isTracking)
        #expect(tracker.offset == 0)
        #expect(tracker.end(time: end) == .cancel)
    }

    // Повели влево, а в конце резко дёрнули вправо: быстрый взмах против направления не листает.
    @Test func flickAgainstDirectionDoesNotTurn() {
        var tracker = SwipeTracker(width: 1000, canGoNext: true, canGoPrevious: true)
        var time: TimeInterval = 0
        for _ in 0..<20 { time += 0.05; tracker.move(dx: -10, dy: 0, time: time) }  // −200 медленно
        for _ in 0..<3 { time += 1.0 / 60; tracker.move(dx: 15, dy: 0, time: time) }  // быстро вправо
        #expect(tracker.end(time: time) == .cancel)
    }

    // Быстрый взмах, а при отрыве пальцев трекпад прислал рывок назад на пару пунктов — всё равно листает.
    @Test func liftJitterStillTurns() {
        var tracker = SwipeTracker(width: 1000, canGoNext: true, canGoPrevious: true)
        var time: TimeInterval = 0
        for _ in 0..<5 { time += 1.0 / 60; tracker.move(dx: -8, dy: 0, time: time) }  // −40 быстро
        time += 0.06  // пальцы на миг замерли — в окне скорости остался только рывок отрыва
        tracker.move(dx: 3, dy: 0, time: time)
        #expect(tracker.end(time: time) == .next)
    }
}

struct SwipeSelectTests {
    // Поиск показанного файла в окне Finder — от выделенного в обе стороны, ближние первыми.
    @Test func outwardSearchOrder() {
        #expect(FinderBridge.outward(from: 2, count: 5) == [2, 3, 1, 4, 0])
        #expect(FinderBridge.outward(from: 0, count: 3) == [0, 1, 2])
        #expect(FinderBridge.outward(from: 2, count: 3) == [2, 1, 0])
        #expect(FinderBridge.outward(from: 0, count: 1) == [0])
        #expect(FinderBridge.outward(from: 3, count: 3).isEmpty)
    }
}

struct PrefetchSidesTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func nextAndPreviousSkipDocuments() {
        let items: [URL?] = [url("a.png"), url("b.txt"), url("c.png"), nil, url("d.png")]
        let sides = PrefetchWindow.sides(
            of: 2, count: items.count, url: { items[$0] }, isImage: { $0.pathExtension == "png" }
        )
        #expect(sides.next == url("d.png"))
        #expect(sides.previous == url("a.png"))
        #expect(sides.prefetchOrder(backwards: false) == [url("d.png"), url("a.png")])
    }

    private let sides = PrefetchWindow.Neighbors(
        forward: [URL(fileURLWithPath: "/tmp/f1"), URL(fileURLWithPath: "/tmp/f2")],
        backward: [URL(fileURLWithPath: "/tmp/b1"), URL(fileURLWithPath: "/tmp/b2")]
    )

    // Две в сторону листания, одна позади: назад — зеркально.
    @Test func prefetchFollowsDirection() {
        #expect(sides.prefetchOrder(backwards: false) == [url("f1"), url("b1"), url("f2")])
        #expect(sides.prefetchOrder(backwards: true) == [url("b1"), url("f1"), url("b2")])
    }

    // Смахнули на соседа — его соседи известны без Finder; на картинку не из соседей — нет.
    @Test func recenteredOnNeighbor() {
        let ahead = sides.recentered(around: url("c"), to: url("f1"))
        #expect(ahead == PrefetchWindow.Neighbors(forward: [url("f2")], backward: [url("c"), url("b1"), url("b2")]))
        let behind = sides.recentered(around: url("c"), to: url("b1"))
        #expect(behind == PrefetchWindow.Neighbors(forward: [url("c"), url("f1"), url("f2")], backward: [url("b2")]))
        #expect(sides.recentered(around: url("c"), to: url("c")) == sides)
        #expect(sides.recentered(around: url("c"), to: url("x")) == nil)
    }

    // Два назад подряд: после первого «предыдущая» ещё известна.
    @Test func twoQuickStepsBack() {
        let first = sides.recentered(around: url("c"), to: url("b1"))
        #expect(first?.previous == url("b2"))
    }

    @Test func mergeKeepsLongerSides() {
        let short = PrefetchWindow.Neighbors(forward: [url("f1")], backward: [url("b1"), url("b2")])
        let long = PrefetchWindow.Neighbors(forward: [url("f1"), url("f2")], backward: [url("b1")])
        #expect(short.merged(with: long) == PrefetchWindow.Neighbors(forward: [url("f1"), url("f2")], backward: [url("b1"), url("b2")]))
    }
}
