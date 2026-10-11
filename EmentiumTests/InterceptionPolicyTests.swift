import CoreGraphics
import Foundation
import Testing
@testable import Ementium

struct InterceptionPolicyTests {
    private let photo = URL(fileURLWithPath: "/tmp/photo.jpg")
    private let space = InterceptionPolicy.spaceKeyCode

    /// Состояние, в котором Пробел должен перехватываться. Каждый тест ломает ровно одно условие.
    private var ready: InterceptionSnapshot {
        InterceptionSnapshot(
            isEnabled: true,
            isFinderFrontmost: true,
            isViewerVisible: false,
            isFinderStateStale: false,
            isTextFieldFocused: false,
            selection: [photo],
            selectionHasImage: true
        )
    }

    private func decide(
        keyCode: UInt16? = nil, flags: CGEventFlags = [], isRepeat: Bool = false,
        _ change: (inout InterceptionSnapshot) -> Void = { _ in }
    ) -> InterceptionPolicy.Decision {
        var state = ready
        change(&state)
        return InterceptionPolicy.decide(keyCode: keyCode ?? space, flags: flags, isRepeat: isRepeat, state: state)
    }

    @Test func spaceOnImageInFinderIsAbsorbedWithTheSelection() {
        #expect(decide() == .absorb([photo]))
    }

    @Test func mixedSelectionIsAbsorbedWholeAndFilteredByTheViewer() {
        let pdf = URL(fileURLWithPath: "/tmp/doc.pdf")
        #expect(decide { $0.selection = [pdf, photo] } == .absorb([pdf, photo]))
    }

    @Test func otherKeysPass() {
        #expect(decide(keyCode: 0) == .pass)
        #expect(decide(keyCode: 36) == .pass)
    }

    @Test(arguments: [CGEventFlags.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
    func spaceWithModifierPasses(flag: CGEventFlags) {
        #expect(decide(flags: flag) == .pass)
    }

    // Caps Lock и служебные флаги клавиатуры не должны мешать.
    @Test func capsLockDoesNotBlock() {
        #expect(decide(flags: [.maskAlphaShift, .maskNonCoalesced]) == .absorb([photo]))
    }

    @Test func autoRepeatPasses() {
        #expect(decide(isRepeat: true) == .pass)
    }

    @Test func disabledInterceptionPasses() {
        #expect(decide { $0.isEnabled = false } == .pass)
    }

    @Test func otherFrontmostAppPasses() {
        #expect(decide { $0.isFinderFrontmost = false } == .pass)
    }

    // Пробел в открытом просмотре закрывает его, а не открывает заново.
    @Test func openViewerPasses() {
        #expect(decide { $0.isViewerVisible = true } == .pass)
    }

    @Test func staleFinderStatePasses() {
        #expect(decide { $0.isFinderStateStale = true } == .pass)
    }

    @Test func textFieldFocusPasses() {
        #expect(decide { $0.isTextFieldFocused = true } == .pass)
    }

    @Test func selectionWithoutImagesPasses() {
        #expect(decide { $0.selectionHasImage = false } == .pass)
    }

    @Test func emptySelectionPasses() {
        #expect(decide { $0.selection = []; $0.selectionHasImage = false } == .pass)
    }

    // Начальное состояние до первого снимка Finder — ничего не перехватывать.
    @Test func initialStatePasses() {
        let state = InterceptionSnapshot()
        #expect(InterceptionPolicy.decide(keyCode: space, flags: [], isRepeat: false, state: state) == .pass)
    }
}

struct InterceptionStateTests {
    @Test func updatesAreVisibleInSnapshot() {
        let state = InterceptionState()
        state.update { $0.isViewerVisible = true }
        #expect(state.snapshot.isViewerVisible)
    }

    @Test func concurrentUpdatesAreNotLost() async {
        let state = InterceptionState()
        let url = URL(fileURLWithPath: "/tmp/x.png")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask { state.update { $0.selection.append(url) } }
            }
        }
        #expect(state.snapshot.selection.count == 1000)
    }
}
