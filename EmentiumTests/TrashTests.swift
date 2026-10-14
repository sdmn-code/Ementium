import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Ementium

struct TrashTargetTests {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    private let isImage: (URL) -> Bool = { $0.pathExtension == "png" }

    private func target(_ names: [String], deleting index: Int) -> URL? {
        let items = names.map(url)
        return TrashTarget.choose(deleting: index, count: items.count, url: { items[$0] }, isImage: isImage)
    }

    // Та же папка, что в прототипе FinderTrashProbe.
    private let folder = ["01.png", "02.png", "03.txt", "04.png", "05.txt", "06.txt", "07.png", "08.txt", "09.png"]

    @Test func nextImageAheadSkippingDocuments() {
        #expect(target(folder, deleting: 0) == url("02.png"))
        #expect(target(folder, deleting: 3) == url("07.png"))  // через 05.txt, 06.txt
        #expect(target(folder, deleting: 6) == url("09.png"))
    }

    @Test func lastImageGoesBack() {
        #expect(target(folder, deleting: 8) == url("07.png"))
        #expect(target(["a.png", "b.txt", "c.png", "d.txt"], deleting: 2) == url("a.png"))
    }

    // Заголовки групп (без файла) пропускаются; цель дальше предела не ищется.
    @Test func groupHeadersAndLimit() {
        let items: [URL?] = [url("a.png"), nil, url("b.txt"), nil, url("c.png")]
        #expect(TrashTarget.choose(deleting: 0, count: items.count, url: { items[$0] }, isImage: isImage) == url("c.png"))
        #expect(TrashTarget.choose(deleting: 0, count: items.count, url: { items[$0] }, isImage: isImage, limit: 2) == nil)
    }

    @Test func onlyImageHasNoTarget() {
        #expect(target(["a.txt", "b.png", "c.txt"], deleting: 1) == nil)
        #expect(target(["b.png"], deleting: 0) == nil)
    }
}

final class TrashCheckTests {
    private let file: URL

    init() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumTrash-\(UUID().uuidString).png")
        try Data("x".utf8).write(to: file)
    }

    deinit {
        var unlocked = file
        var values = URLResourceValues()
        values.isUserImmutable = false
        try? unlocked.setResourceValues(values)
        try? FileManager.default.removeItem(at: file)
    }

    @Test func ordinaryFileCanBeTrashed() {
        #expect(TrashCheck.check(file) == nil)
    }

    // Защищённый файл Finder переспросил бы — диалог оказался бы под оверлеем.
    @Test func lockedFileIsNotTrashed() throws {
        var locked = file
        var values = URLResourceValues()
        values.isUserImmutable = true
        try locked.setResourceValues(values)
        #expect(TrashCheck.check(file) == .locked)
    }

    @Test func missingFile() {
        #expect(TrashCheck.check(file.appendingPathExtension("gone")) == .missing)
    }

    // Открыт прямо из Корзины — ⌘⌫ удалил бы его насовсем.
    @Test func filesInTrashAreRecognized() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(TrashCheck.isInTrash(home.appendingPathComponent(".Trash/photo.jpg")))
        #expect(TrashCheck.isInTrash(URL(fileURLWithPath: "/Volumes/Card/.Trashes/501/photo.jpg")))
        #expect(!TrashCheck.isInTrash(home.appendingPathComponent("Pictures/Trash/photo.jpg")))
    }

    // Нет прав на запись в папку — удалить нельзя.
    @Test func readOnlyFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumRO-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("a.png")
        try Data("x".utf8).write(to: inside)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        #expect(TrashCheck.check(inside) == .noPermission)
    }
}

struct TrashKeyTests {
    private func action(_ keyCode: UInt16, _ characters: String?, _ flags: CGEventFlags, enabled: Bool) -> ViewerKeyAction {
        InterceptionPolicy.followingAction(
            keyCode: keyCode, characters: characters, flags: flags, isRepeat: false, systemShortcuts: [], trashEnabled: enabled
        )
    }

    @Test func commandDeleteTrashesOnlyWhenEnabled() {
        #expect(action(51, nil, .maskCommand, enabled: true) == .trash)
        #expect(action(51, nil, .maskCommand, enabled: false) == .trashOff)  // подсказка, где включить
        // ⌥⌘⌫ — «Удалить немедленно» в Finder — по-прежнему проглатывается.
        #expect(action(51, nil, [.maskCommand, .maskAlternate], enabled: true) == .swallow)
    }

    // Зажатый ⌘⌫ не удаляет папку по картинке, зажатый ⌘Z не возвращает всё подряд.
    @Test func autorepeatNeverTrashesOrUndoes() {
        func repeated(_ keyCode: UInt16, _ characters: String?, enabled: Bool = true) -> ViewerKeyAction {
            InterceptionPolicy.followingAction(
                keyCode: keyCode, characters: characters, flags: .maskCommand, isRepeat: true,
                systemShortcuts: [], trashEnabled: enabled
            )
        }
        #expect(repeated(51, nil) == .swallow)
        #expect(repeated(6, "z") == .swallow)
        // И подсказка «включите в настройках» не мигает на каждом повторе.
        #expect(repeated(51, nil, enabled: false) == .swallow)
    }

    @Test func commandZUndoesOnlyWhenEnabled() {
        #expect(action(6, "z", .maskCommand, enabled: true) == .undoTrash)
        #expect(action(6, "я", .maskCommand, enabled: true) == .undoTrash)  // русская раскладка — по физическому коду
        #expect(action(6, "z", .maskCommand, enabled: false) == .swallow)
    }

    @Test func ownListCommands() {
        #expect(ViewerCommand(keyCode: 51, characters: nil, modifiers: .command) == .trash)
        #expect(ViewerCommand(keyCode: 6, characters: "z", modifiers: .command) == .undo)
        #expect(ViewerCommand(keyCode: 51, characters: nil, modifiers: []) == nil)
    }
}
