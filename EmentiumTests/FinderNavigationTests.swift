import CoreGraphics
import Foundation
import Testing
@testable import Ementium

struct FinderViewKindTests {
    @Test(arguments: [FinderViewKind.list, .columns])
    func listAndColumnsGoVertically(kind: FinderViewKind) {
        #expect(kind.finderKey(for: .right) == .down)
        #expect(kind.finderKey(for: .down) == .down)
        #expect(kind.finderKey(for: .left) == .up)
        #expect(kind.finderKey(for: .up) == .up)
    }

    // В галерее ↑↓ ничего не делают (прототип FinderFollowProbe) — переводим в ←→.
    @Test func galleryGoesHorizontally() {
        #expect(FinderViewKind.gallery.finderKey(for: .down) == .right)
        #expect(FinderViewKind.gallery.finderKey(for: .up) == .left)
        #expect(FinderViewKind.gallery.finderKey(for: .right) == .right)
    }

    // В значках — последовательно, как в списке (решение Саши): путь через ряды строит IconGridPath.
    @Test func iconsGoSequentially() {
        #expect(FinderViewKind.icons.finderKey(for: .down) == .right)
        #expect(FinderViewKind.icons.finderKey(for: .up) == .left)
    }

    // Прочие виды — стрелка как есть. Рабочий стол стрелок Finder не получает (шаг — выделение через AX).
    @Test(arguments: [ArrowKey.left, .right, .up, .down])
    func otherKeepsTheKey(key: ArrowKey) {
        #expect(FinderViewKind.other.finderKey(for: key) == key)
        #expect(FinderViewKind.desktop.finderKey(for: key) == key)
    }
}

/// Рабочий стол — по рядам, как текст (решение Саши); в AX значки идут вперемешку.
struct DesktopOrderTests {
    // Раскладка Саши: три столбца у правого края (x = 1364, 1488, 1612), ряды через 112 пт.
    @Test func gridByRows() {
        let positions: [CGPoint?] = [
            CGPoint(x: 1612, y: 42), CGPoint(x: 1488, y: 602), CGPoint(x: 1488, y: 714), CGPoint(x: 1488, y: 378),
            CGPoint(x: 1612, y: 378), CGPoint(x: 1364, y: 42), CGPoint(x: 1488, y: 42),
        ]
        #expect(DesktopOrder.order(of: positions, rowTolerance: 32) == [5, 6, 0, 3, 4, 1, 2])
    }

    // Расставленные вручную: в ряду y чуть разные — всё равно один ряд, слева направо.
    @Test func jitteredRow() {
        let positions: [CGPoint?] = [CGPoint(x: 230, y: 97), CGPoint(x: 10, y: 100), CGPoint(x: 120, y: 104)]
        #expect(DesktopOrder.order(of: positions, rowTolerance: 32) == [1, 2, 0])
    }

    // Ряд ниже допуска — уже следующий, даже если значок левее.
    @Test func nextRowEvenIfLeft() {
        let positions: [CGPoint?] = [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 0)]
        #expect(DesktopOrder.order(of: positions, rowTolerance: 32) == [1, 0])
    }

    @Test func withoutPositionGoesLast() {
        let positions: [CGPoint?] = [nil, CGPoint(x: 0, y: 0)]
        #expect(DesktopOrder.order(of: positions, rowTolerance: 32) == [1, 0])
    }
}

/// Сетка 7 столбцов (x = 0, 100 … 600), ряды y = 0, 100 … 600; в последнем ряду один значок.
struct IconGridPathTests {
    private let rows: [CGFloat] = [0, 100, 200, 300, 400, 500, 600]
    private let cols: [CGFloat] = [0, 100, 200, 300, 400, 500, 600]

    private func keys(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat)) -> [ArrowKey]? {
        IconGridPath.keys(from: CGPoint(x: from.0, y: from.1), to: CGPoint(x: to.0, y: to.1), rowYs: rows, colXs: cols)
    }

    @Test func sameRowGoesHorizontally() {
        #expect(keys((100, 200), (400, 200)) == [.right, .right, .right])
        #expect(keys((400, 200), (300, 200)) == [.left])
    }

    // Вниз: сначала по своему (полному) ряду, потом вниз.
    @Test func downwardsGoesAlongTheRowFirst() {
        #expect(keys((0, 0), (600, 500)) == [.right, .right, .right, .right, .right, .right, .down, .down, .down, .down, .down])
    }

    // Случай из прототипа: из короткого последнего ряда вверх — сначала вверх, иначе → упрётся в пустоту.
    @Test func upwardsFromAShortLastRowGoesUpFirst() {
        #expect(keys((0, 600), (100, 500)) == [.up, .right])
    }

    // AX отдал значки вперемешку — восстанавливаем порядок экрана: по рядам, слева направо.
    @Test func displayOrderIsRowMajorForIcons() {
        let shuffled: [CGPoint?] = [
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 0), nil, CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 0),
        ]
        #expect(IconGridPath.displayOrder(of: shuffled, rowMajor: true) == [1, 4, 3, 0, 2])
    }

    @Test func displayOrderIsLeftToRightForGallery() {
        let strip: [CGPoint?] = [CGPoint(x: 300, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 0)]
        #expect(IconGridPath.displayOrder(of: strip, rowMajor: false) == [1, 2, 0])
    }

    @Test func positionsOffTheGridGiveNil() {
        #expect(keys((50, 0), (100, 0)) == nil)
    }
}

struct FinderNavigationLookAgainTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    // Картинки среди подгруженных нет — прыгаем на последний подгруженный; там Finder подгрузит следующие.
    @Test func landingOnTheLastLoadedItemAsksToLookAgain() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.jump([.right, .right], direction: .right, to: url("loaded-last.txt"))
        #expect(nav.selectionChanged(to: url("b.txt"), isImage: false) == [])
        #expect(nav.selectionChanged(to: url("loaded-last.txt"), isImage: false) == [.lookAgain(.right)])
        #expect(nav.mode == .stepping(.right))
    }
}



/// Автомат листания на поддельном Finder: что отправляем и что показываем.
struct FinderNavigationTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func stepToAnImageShowsIt() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        #expect(nav.userStep(.down) == [.send(.down)])
        #expect(nav.selectionChanged(to: url("b.jpg"), isImage: true) == [.show(url("b.jpg"))])
        #expect(nav.shown == url("b.jpg"))
    }

    @Test func nonImagesAreSkippedInTheSameDirection() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.userStep(.up)
        #expect(nav.selectionChanged(to: url("clip.mov"), isImage: false) == [.send(.up)])
        #expect(nav.selectionChanged(to: url("doc.pdf"), isImage: false) == [.send(.up)])
        #expect(nav.selectionChanged(to: url("c.jpg"), isImage: true) == [.show(url("c.jpg"))])
    }

    // Два уведомления на один шаг Finder — не два шага (ревью, п. 5).
    @Test func duplicateNotificationIsIgnored() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.userStep(.down)
        #expect(nav.selectionChanged(to: url("clip.mov"), isImage: false) == [.send(.down)])
        #expect(nav.selectionChanged(to: url("clip.mov"), isImage: false) == [])
    }

    @Test func edgeOnAnImageStaysPut() {
        var nav = FinderNavigation(showing: url("last.jpg"))
        _ = nav.userStep(.down)
        #expect(nav.timedOut() == [])
        #expect(nav.mode == .idle)
        #expect(nav.shown == url("last.jpg"))
    }

    // В конце папки за последней картинкой — видео: на краю шагаем назад, пока не встанем на картинку.
    @Test func edgeAfterNonImagesReturnsUntilAnImage() {
        var nav = FinderNavigation(showing: url("last.jpg"))
        _ = nav.userStep(.down)
        _ = nav.selectionChanged(to: url("a.mov"), isImage: false)
        _ = nav.selectionChanged(to: url("b.mov"), isImage: false)
        #expect(nav.timedOut() == [.send(.up)])
        #expect(nav.selectionChanged(to: url("a.mov"), isImage: false) == [.send(.up)])
        #expect(nav.selectionChanged(to: url("last.jpg"), isImage: true) == [])
        #expect(nav.mode == .idle)
    }

    // Зажатая стрелка у хвоста из видео: каждый автоповтор — новый шаг, но возврат всё равно доходит
    // до картинки, сколько бы видео ни было (ревью, п. 3).
    @Test func heldArrowAtVideoTailStillReturnsAllTheWay() {
        var nav = FinderNavigation(showing: url("last.jpg"))
        for name in ["1.mov", "2.mov", "3.mov", "4.mov", "5.mov"] {
            _ = nav.userStep(.down)
            _ = nav.selectionChanged(to: url(name), isImage: false)
        }
        #expect(nav.timedOut() == [.send(.up)])
        for name in ["4.mov", "3.mov", "2.mov", "1.mov"] {
            #expect(nav.selectionChanged(to: url(name), isImage: false) == [.send(.up)])
        }
        #expect(nav.selectionChanged(to: url("last.jpg"), isImage: true) == [])
        #expect(nav.mode == .idle)
    }

    // Finder стоит на видео за показанной картинкой; шаг назад приводит на неё же — шагаем дальше,
    // к предыдущей картинке, а не тратим нажатие впустую (ревью, п. 6).
    @Test func stepBackFromTheTailContinuesPastTheShownImage() {
        var nav = FinderNavigation(showing: url("b.jpg"))
        _ = nav.userStep(.down)
        _ = nav.selectionChanged(to: url("x.mov"), isImage: false)
        _ = nav.userStep(.up)
        #expect(nav.selectionChanged(to: url("b.jpg"), isImage: true) == [.send(.up)])
        #expect(nav.selectionChanged(to: url("a.jpg"), isImage: true) == [.show(url("a.jpg"))])
    }

    // Двойное нажатие: первый шаг нашёл картинку, ответ на второй — видео. Его тоже пропускаем (ревью, п. 7).
    @Test func secondStepInFlightAfterAnImageIsStillSkipped() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.userStep(.down)
        _ = nav.userStep(.down)
        #expect(nav.selectionChanged(to: url("b.jpg"), isImage: true) == [.show(url("b.jpg"))])
        #expect(nav.selectionChanged(to: url("c.mov"), isImage: false) == [.send(.down)])
        #expect(nav.selectionChanged(to: url("d.jpg"), isImage: true) == [.show(url("d.jpg"))])
    }

    // Поздний ответ Finder после таймаута: картинка показывается, а лишних шагов нет.
    @Test func lateImageAfterTimeoutIsShown() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.userStep(.down)
        #expect(nav.timedOut() == [])
        #expect(nav.selectionChanged(to: url("b.jpg"), isImage: true) == [.show(url("b.jpg"))])
    }

    @Test func skippingLimitTurnsBack() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.userStep(.down)
        for i in 1...FinderNavigation.maxSkips {
            #expect(nav.selectionChanged(to: url("\(i).pdf"), isImage: false) == [.send(.down)])
        }
        #expect(nav.selectionChanged(to: url("last.pdf"), isImage: false) == [.send(.up)])
        #expect(nav.mode == .returning(.up))
    }

    // Esc во время пропуска: выделение Finder возвращается на картинку, новых показов нет (ревью, п. 8).
    @Test func finishReturnsFinderToTheLastImage() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.userStep(.right)
        _ = nav.selectionChanged(to: url("x.mov"), isImage: false)
        #expect(nav.finish() == [.send(.left)])
        #expect(!nav.isDone)
        #expect(nav.userStep(.right) == [])
        #expect(nav.selectionChanged(to: url("a.jpg"), isImage: true) == [])
        #expect(nav.isDone)
    }

    @Test func finishOnAnImageIsDoneAtOnce() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        #expect(nav.finish() == [])
        #expect(nav.isDone)
    }

    // Прыжок пачкой: сразу N стрелок, промежуточные документы не вызывают новых шагов.
    // Соседей для предзагрузки читаем сразу после приземления на картинку, не дожидаясь таймаута шага
    // (ревью v0.5: иначе чтение откладывалось на 0,3 с после каждого шага).
    @Test func settledRightAfterLandingOnAnImage() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        #expect(nav.isSettled)
        _ = nav.userStep(.down)
        #expect(nav.isSettled == true)  // Finder ещё не ответил, но стоит на показанной картинке
        _ = nav.selectionChanged(to: url("doc.pdf"), isImage: false)
        #expect(!nav.isSettled)
        _ = nav.selectionChanged(to: url("b.jpg"), isImage: true)
        #expect(nav.mode == .stepping(.down))
        #expect(nav.isSettled)
    }

    @Test func notSettledWhileJumpingReturningOrFinishing() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.jump([.down, .down], direction: .down, to: url("c.jpg"))
        #expect(!nav.isSettled)
        _ = nav.selectionChanged(to: url("c.jpg"), isImage: true)
        #expect(nav.isSettled)

        var tail = FinderNavigation(showing: url("a.jpg"))
        _ = tail.userStep(.down)
        _ = tail.selectionChanged(to: url("clip.mov"), isImage: false)
        _ = tail.timedOut()  // край после видео — возвращаемся
        #expect(tail.mode == .returning(.up))
        #expect(!tail.isSettled)

        var closing = FinderNavigation(showing: url("a.jpg"))
        _ = closing.finish()
        #expect(!closing.isSettled)
    }

    @Test func jumpSendsAllStepsAndIgnoresDocumentsOnTheWay() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        #expect(nav.jump(Array(repeating: .down, count: 3), direction: .down, to: url("d.jpg")) == Array(repeating: .send(.down), count: 3))
        #expect(nav.isJumping)
        #expect(nav.selectionChanged(to: url("b.txt"), isImage: false) == [])
        #expect(nav.selectionChanged(to: url("c.txt"), isImage: false) == [])
        #expect(nav.selectionChanged(to: url("d.jpg"), isImage: true) == [.show(url("d.jpg"))])
        #expect(!nav.isJumping)
    }

    // Пачка «потерялась» и Finder встал на документе — дальше по одному шагу в ту же сторону.
    @Test func jumpThatStopsShortContinuesStepByStep() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.jump(Array(repeating: .down, count: 3), direction: .down, to: url("d.jpg"))
        _ = nav.selectionChanged(to: url("b.txt"), isImage: false)
        #expect(nav.timedOut() == [.send(.down)])
        #expect(nav.mode == .stepping(.down))
        #expect(nav.selectionChanged(to: url("c.txt"), isImage: false) == [.send(.down)])
    }

    @Test func jumpTimeoutOnAnImageEnds() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.jump(Array(repeating: .down, count: 2), direction: .down, to: url("c.jpg"))
        #expect(nav.timedOut() == [])
        #expect(nav.mode == .idle)
    }

    @Test func emptyJumpSendsNothing() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        #expect(nav.jump(Array(repeating: .down, count: 0), direction: .down, to: url("a.jpg")) == [])
        #expect(!nav.isJumping)
    }

    // Esc посреди прыжка: возвращаемся на последнюю показанную картинку.
    @Test func finishDuringJumpReturns() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        _ = nav.jump(Array(repeating: .down, count: 5), direction: .down, to: url("f.jpg"))
        _ = nav.selectionChanged(to: url("b.txt"), isImage: false)
        #expect(nav.finish() == [.send(.up)])
        #expect(nav.jump(Array(repeating: .down, count: 1), direction: .down, to: url("f.jpg")) == [])
    }

    @Test func stayKeepsFinderWhereItIs() {
        var nav = FinderNavigation(showing: url("last.jpg"))
        _ = nav.userStep(.down)
        nav.stay()
        #expect(nav.mode == .idle)
        #expect(nav.timedOut() == [])
    }

    @Test func selectionChangesWithoutOurStepAreShownButDoNotStep() {
        var nav = FinderNavigation(showing: url("a.jpg"))
        #expect(nav.selectionChanged(to: url("b.jpg"), isImage: true) == [.show(url("b.jpg"))])
        #expect(nav.selectionChanged(to: url("doc.pdf"), isImage: false) == [])
    }
}

/// Сочетания из настроек Саши (macOS 27): ⌘Пробел и ⌃⌘Пробел — смена языка, ⌥⌘Пробел — Spotlight.
private var sashaHotKeys: [String: Any] { [
    "60": ["enabled": true, "value": ["parameters": [32, 49, 1_048_576]]],     // ⌘Пробел — пред. язык
    "61": ["enabled": true, "value": ["parameters": [32, 49, 1_310_720]]],     // ⌃⌘Пробел — след. язык
    "64": ["enabled": true, "value": ["parameters": [32, 49, 1_572_864]]],     // ⌥⌘Пробел — Spotlight
    "65": ["enabled": false, "value": ["parameters": [65535, 49, 1_572_864]]], // поиск Finder — выключен
    "32": ["enabled": true, "value": ["parameters": [65535, 126, 262_144]]],   // ⌃↑ — Mission Control
    "36": ["enabled": true, "value": ["parameters": [65535, 103, 8_388_608]]], // F11 (с флагом fn)
    "79": ["enabled": true],                                                    // ⌃← — стандартное
    "28": ["enabled": true, "value": ["parameters": [51, 20, 1_179_648]]],     // ⇧⌘3
    "30": ["enabled": true, "value": ["parameters": [52, 21, 1_179_648]]],     // ⇧⌘4
] }

struct SystemShortcutsTests {
    private let shortcuts = SystemShortcuts.parse(sashaHotKeys)

    private func find(_ keyCode: UInt16, _ modifiers: CGEventFlags) -> SystemShortcut? {
        shortcuts.first { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }

    @Test func remappedShortcutsAreReadFromSettings() {
        #expect(find(49, .maskCommand)?.action == .pass)                          // смена языка — остаёмся
        #expect(find(49, [.maskControl, .maskCommand])?.action == .pass)
        #expect(find(49, [.maskAlternate, .maskCommand])?.action == .passAndClose) // Spotlight
    }

    @Test func disabledShortcutIsIgnored() {
        // Поиск Finder выключен и совпадает со Spotlight — Spotlight должен остаться единственным.
        #expect(shortcuts.filter { $0.keyCode == 49 && $0.modifiers == [.maskAlternate, .maskCommand] }.count == 1)
    }

    @Test func entryWithoutKeysUsesTheStandardShortcut() {
        #expect(find(123, .maskControl)?.action == .passAndClose)  // ⌃← — рабочий стол слева
    }

    @Test func functionFlagIsIgnored() {
        #expect(find(103, [])?.action == .passAndClose)
    }

    @Test func screenshotsKeepTheViewerOpen() {
        #expect(find(21, [.maskCommand, .maskShift])?.action == .pass)
    }

    // Без своих настроек (свежая система) — стандартные: ⌘Пробел — Spotlight, ⌃Пробел — язык.
    @Test func freshSystemUsesStandardShortcuts() {
        let standard = SystemShortcuts.parse([:])
        #expect(standard.first { $0.keyCode == 49 && $0.modifiers == .maskCommand }?.action == .passAndClose)
        #expect(standard.first { $0.keyCode == 49 && $0.modifiers == .maskControl }?.action == .pass)
    }
}

/// Клавиши при открытом просмотре в режиме «следовать за Finder».
struct FollowingKeyPolicyTests {
    private let shortcuts = SystemShortcuts.parse(sashaHotKeys)

    private func action(_ keyCode: UInt16, _ characters: String? = nil, _ flags: CGEventFlags = [], repeat isRepeat: Bool = false) -> ViewerKeyAction {
        InterceptionPolicy.followingAction(
            keyCode: keyCode, characters: characters, flags: flags, isRepeat: isRepeat, systemShortcuts: shortcuts
        )
    }

    @Test func arrowsStep() {
        #expect(action(124) == .step(.right))
        #expect(action(125, nil, [.maskNumericPad, .maskSecondaryFn]) == .step(.down))  // служебные флаги стрелок
        #expect(action(123, nil, .maskAlphaShift) == .step(.left))                     // Caps Lock не мешает
        #expect(action(126, nil, [], repeat: true) == .step(.up))                      // зажатая стрелка листает
    }

    @Test func escapeAndSpaceClose() {
        #expect(action(53) == .close)
        #expect(action(49, " ") == .close)
    }

    // Автоповтор Пробела, которым открыли просмотр, не закрывает его.
    @Test func spaceRepeatIsSwallowed() {
        #expect(action(49, " ", [], repeat: true) == .swallow)
    }

    @Test func commandQQuits() {
        #expect(action(12, "q", .maskCommand) == .quit)
        #expect(action(12, "й", .maskCommand) == .quit)
    }

    // Случай Саши: ⌘Пробел меняет язык — просмотр не закрывается; ⌥⌘Пробел — Spotlight — закрывается.
    @Test func sashasInputSourceAndSpotlight() {
        #expect(action(49, nil, .maskCommand) == .pass)
        #expect(action(49, nil, [.maskAlternate, .maskCommand]) == .passAndClose)
    }

    // Запускалки сторонних приложений (Alfred, Raycast) в системных настройках не видны.
    @Test func anyModifierSpaceFallsBackToPassAndClose() {
        #expect(action(49, nil, .maskAlternate) == .passAndClose)
        #expect(action(49, nil, [.maskShift, .maskCommand]) == .passAndClose)
    }

    static let leavingShortcuts: [(UInt16, CGEventFlags)] = [
        (48, .maskCommand),                   // ⌘Tab
        (48, [.maskCommand, .maskShift]),     // ⇧⌘Tab
        (50, .maskCommand),                   // ⌘`
        (53, [.maskCommand, .maskAlternate]), // ⌥⌘Esc — принудительное завершение
        (12, [.maskControl, .maskCommand]),   // ⌃⌘Q — блокировка экрана
        (126, .maskControl),                  // ⌃↑ — Mission Control (из настроек)
        (123, .maskControl),                  // ⌃← — рабочий стол (стандартное)
        (99, []),                             // F3
        (103, []),                            // F11 — рабочий стол
    ]

    @Test(arguments: leavingShortcuts)
    func leavingShortcutsPassAndClose(keyCode: UInt16, flags: CGEventFlags) {
        #expect(action(keyCode, nil, flags) == .passAndClose)
    }

    @Test func screenshotsPass() {
        #expect(action(21, nil, [.maskCommand, .maskShift]) == .pass)
    }

    @Test func commandCommaOpensSettingsInFollowMode() {
        #expect(action(43, ",", .maskCommand) == .openSettings)
    }

    // Настройка «Пробел закрывает просмотр» выключена — закрывает только Esc.
    @Test func spaceDoesNotCloseWhenDisabled() {
        let disabled = InterceptionPolicy.followingAction(
            keyCode: 49, characters: " ", flags: [], isRepeat: false, systemShortcuts: [], spaceClosesViewer: false
        )
        #expect(disabled == .swallow)
        let escape = InterceptionPolicy.followingAction(
            keyCode: 53, characters: nil, flags: [], isRepeat: false, systemShortcuts: [], spaceClosesViewer: false
        )
        #expect(escape == .close)
    }

    // Масштаб в режиме «следовать»: клавиатура у Finder, клавиши масштаба разбирает перехват.
    @Test func zoomKeysZoom() {
        #expect(action(24) == .zoom(.zoomIn))
        #expect(action(24, nil, .maskShift) == .zoom(.zoomIn))
        #expect(action(27, nil, .maskCommand) == .zoom(.zoomOut))
        #expect(action(82, nil, .maskNumericPad) == .zoom(.zoomFit))
        #expect(action(24, nil, [], repeat: true) == .zoom(.zoomIn))  // зажатый «+» тоже увеличивает
    }

    // Ничего не должно невидимо сработать в Finder за оверлеем.
    static let finderShortcuts: [(UInt16, CGEventFlags)] = [
        (36, []),                                             // Return — переименование
        (0, []),                                              // буква — поиск по имени
        (51, [.maskCommand, .maskAlternate]),                 // ⌥⌘⌫ — удалить немедленно
        (51, [.maskCommand, .maskShift]),                     // ⇧⌘⌫ — очистить Корзину
        (51, [.maskCommand, .maskShift, .maskAlternate]),     // ⌥⇧⌘⌫ — очистить Корзину без вопросов
        (45, [.maskControl, .maskCommand]),                   // ⌃⌘N — новая папка с выбранным
        (9, [.maskCommand, .maskAlternate]),                  // ⌥⌘V — переместить сюда
        (5, [.maskCommand, .maskShift]),                      // ⇧⌘G — переход к папке
        (48, .maskControl),                                   // ⌃Tab — вкладки
        (0, .maskCommand),                                    // ⌘A — выделить всё
        (125, .maskShift),                                    // ⇧↓ — расширить выделение
        (125, .maskCommand),                                  // ⌘↓ — открыть
        (13, .maskCommand),                                   // ⌘W — закрыть окно
        (53, .maskCommand),                                   // ⌘Esc
    ]

    @Test(arguments: finderShortcuts)
    func finderShortcutsAreSwallowed(keyCode: UInt16, flags: CGEventFlags) {
        #expect(action(keyCode, nil, flags) == .swallow)
    }

    // ⌘⌫ без настройки «В Корзину» тоже не доходит до Finder — но с подсказкой, где её включить.
    @Test func commandDeleteWithoutSettingHints() {
        #expect(action(51, nil, .maskCommand) == .trashOff)
    }
}

struct SwallowedKeysTests {
    @Test func swallowedPressSwallowsItsRepeatAndRelease() {
        var keys = SwallowedKeys()
        keys.swallow(49)
        #expect(keys.isHeld(49))
        let first = keys.released(49)
        #expect(first)
        #expect(!keys.isHeld(49))
        let second = keys.released(49)
        #expect(!second)  // второе отпускание — чужое, пропускаем
    }

    // Отпускание потерялось (tap был выключен): новое нажатие той же клавиши забывает старое.
    @Test func newPressForgetsALostRelease() {
        var keys = SwallowedKeys()
        keys.swallow(124)
        keys.pressed(124)
        let released = keys.released(124)
        #expect(!released)
    }

    @Test func resetForgetsEverything() {
        var keys = SwallowedKeys()
        keys.swallow(49)
        keys.swallow(53)
        keys.reset()
        let space = keys.released(49)
        let escape = keys.released(53)
        #expect(!space && !escape)
    }

    @Test func otherKeysPass() {
        var keys = SwallowedKeys()
        keys.swallow(49)
        let other = keys.released(0)
        #expect(!other)
    }
}
