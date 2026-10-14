import Foundation
import Testing
@testable import Ementium

struct SpaceReturnTrackerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func frontWhenLeftRaisesOnReturn() {
        var tracker = SpaceReturnTracker()
        tracker.left(at: t0, isFront: true)
        let raise = tracker.returned()
        #expect(raise)
    }

    @Test func behindOtherWindowsStaysBehind() {
        var tracker = SpaceReturnTracker()
        tracker.lostFront(at: t0.addingTimeInterval(-10))  // щёлкнули по другому приложению задолго до ухода
        tracker.left(at: t0, isFront: false)
        let raise = tracker.returned()
        #expect(!raise)
    }

    // Уведомление о потере фокуса пришло раньше уведомления об уходе.
    @Test func lossJustBeforeLeavingCountsAsFront() {
        var tracker = SpaceReturnTracker()
        tracker.lostFront(at: t0.addingTimeInterval(-0.02))
        tracker.left(at: t0, isFront: false)
        let raise = tracker.returned()
        #expect(raise)
    }

    // Уведомление о потере фокуса пришло позже уведомления об уходе.
    @Test func lossJustAfterLeavingCountsAsFront() {
        var tracker = SpaceReturnTracker()
        tracker.left(at: t0, isFront: false)
        tracker.lostFront(at: t0.addingTimeInterval(0.03))
        let raise = tracker.returned()
        #expect(raise)
    }

    // Ementium поработал на другом столе и потерял фокус там — к окну настроек это не относится.
    @Test func laterLossOnAnotherSpaceIsIgnored() {
        var tracker = SpaceReturnTracker()
        tracker.left(at: t0, isFront: false)
        tracker.lostFront(at: t0.addingTimeInterval(5))
        let raise = tracker.returned()
        #expect(!raise)
    }

    // Решение зафиксировано у ухода: поздняя потеря его не отменяет.
    @Test func laterLossKeepsDecision() {
        var tracker = SpaceReturnTracker()
        tracker.lostFront(at: t0.addingTimeInterval(-0.02))
        tracker.left(at: t0, isFront: false)
        tracker.lostFront(at: t0.addingTimeInterval(5))
        let raise = tracker.returned()
        #expect(raise)
    }

    // 1 → 2 → 3 → 1: переход между чужими столами — тот же уход.
    @Test func hoppingBetweenOtherSpacesIsOneTrip() {
        var tracker = SpaceReturnTracker()
        tracker.left(at: t0, isFront: true)
        tracker.left(at: t0.addingTimeInterval(3), isFront: false)
        let raise = tracker.returned()
        #expect(raise)
        let again = tracker.returned()
        #expect(!again)
    }

    @Test func returnWithoutLeavingDoesNothing() {
        var tracker = SpaceReturnTracker()
        let raise = tracker.returned()
        #expect(!raise)
    }

    // Окно вывели вперёд на другом столе (открыли из меню) — прежний уход забыт.
    @Test func shownForgetsTrip() {
        var tracker = SpaceReturnTracker()
        tracker.left(at: t0, isFront: true)
        tracker.shown()
        #expect(!tracker.isAway)
        let raise = tracker.returned()
        #expect(!raise)
    }
}
