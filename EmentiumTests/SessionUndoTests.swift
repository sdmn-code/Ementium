import Foundation
import Testing
@testable import Ementium

struct SessionUndoTests {
    private let a = URL(fileURLWithPath: "/tmp/a.jpg")
    private let b = URL(fileURLWithPath: "/tmp/b.jpg")

    @Test func emptyHasNothingToUndo() {
        var undo = SessionUndo()
        #expect(undo.isEmpty)
        let entry = undo.undo()
        #expect(entry == nil)
    }

    // Последнее действие отменяется первым, какого бы рода ни были действия.
    @Test func lastInFirstOutAcrossKinds() {
        var undo = SessionUndo()
        undo.record(.trash(a))
        undo.record(.tags(url: b, before: ["Работа"]))
        undo.record(.move(from: a, to: b))
        let first = undo.undo()
        let second = undo.undo()
        let third = undo.undo()
        let fourth = undo.undo()
        #expect(first == .move(from: a, to: b))
        #expect(second == .tags(url: b, before: ["Работа"]))
        #expect(third == .trash(a))
        #expect(fourth == nil)
    }

    // Отменили и снова отметили — новая запись наверху.
    @Test func recordAfterUndo() {
        var undo = SessionUndo()
        undo.record(.tags(url: a, before: []))
        _ = undo.undo()
        undo.record(.tags(url: a, before: ["Красный"]))
        #expect(undo.entries == [.tags(url: a, before: ["Красный"])])
    }

    @Test func clearForgetsEverything() {
        var undo = SessionUndo()
        undo.record(.trash(a))
        undo.record(.copy(b))
        undo.clear()
        #expect(undo.isEmpty)
    }
}
