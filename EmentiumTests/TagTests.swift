import AppKit
import CoreGraphics
import Testing
@testable import Ementium

struct TagToggleTests {
    @Test func addsMissingTagAtTheEnd() {
        #expect(TagToggle.toggled([], "Красный") == ["Красный"])
        #expect(TagToggle.toggled(["Работа"], "Красный") == ["Работа", "Красный"])
    }

    // Метки складываются: вторая цифра добавляет второй цвет, первый остаётся.
    @Test func labelsAddUp() {
        let red = TagToggle.toggled(["Работа"], "Красный")
        #expect(TagToggle.toggled(red, "Синий") == ["Работа", "Красный", "Синий"])
    }

    @Test func removesPresentTagKeepingOthersAndOrder() {
        #expect(TagToggle.toggled(["Работа", "Красный", "Синий"], "Красный") == ["Работа", "Синий"])
        #expect(TagToggle.toggled(["Красный"], "Красный") == [])
    }

    // Finder сравнивает имена тегов без учёта регистра — «красный» на файле и есть «Красный».
    @Test func caseInsensitive() {
        #expect(TagToggle.toggled(["Работа", "красный"], "Красный") == ["Работа"])
        #expect(TagToggle.contains(["RED"], "Red"))
        #expect(!TagToggle.contains(["Красный "], "Красный"))
    }

    // «ё» и «е» — одно имя для Finder; «й» и «и» — разные.
    @Test func yoIsE() {
        #expect(TagToggle.contains(["Жёлтый"], "Желтый"))
        #expect(TagToggle.toggled(["Зеленый"], "Зелёный") == [])
        #expect(!TagToggle.same("Мой", "Мои"))
    }

    @Test func toggleTwiceRestores() {
        let tags = ["Работа", "Синий"]
        let once = TagToggle.toggled(tags, "Красный")
        #expect(TagToggle.toggled(once, "Красный") == tags)
    }
}

struct TagKeyTests {
    private func command(_ keyCode: UInt16, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> ViewerCommand? {
        ViewerCommand(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    /// Верхний ряд и цифровой блок: физические клавиши 1–7.
    static let topRow: [(UInt16, Int)] = [(18, 1), (19, 2), (20, 3), (21, 4), (23, 5), (22, 6), (26, 7)]
    static let keypad: [(UInt16, Int)] = [(83, 1), (84, 2), (85, 3), (86, 4), (87, 5), (88, 6), (89, 7)]

    @Test(arguments: topRow + keypad)
    func digitsToggleTags(keyCode: UInt16, number: Int) {
        #expect(command(keyCode) == .tag(number))
    }

    // AppKit помечает цифровой блок флагом .numericPad, Caps Lock может быть включён — это не модификаторы.
    @Test func keypadAndCapsLockFlagsAreFine() {
        #expect(command(83, "1", .numericPad) == .tag(1))
        #expect(command(18, "1", .capsLock) == .tag(1))
    }

    // По физической клавише: во французской раскладке верхний ряд без ⇧ даёт «&é"'(».
    @Test func physicalKeyInAnyLayout() {
        #expect(command(18, "&") == .tag(1))
        #expect(command(19, "é") == .tag(2))
    }

    @Test func otherDigitsAndModifiersAreNotTags() {
        #expect(command(28) == nil)                       // 8
        #expect(command(25) == nil)                       // 9
        #expect(command(29) == .zoomFit)                  // 0 — по-прежнему «вписать»
        #expect(command(91) == nil)                       // 8 на цифровом блоке
        #expect(command(18, "!", .shift) == nil)          // ⇧1 — перемещение в папки, позже
        #expect(command(18, "1", .control) == nil)        // ⌃1 — рабочий стол
        #expect(command(18, "1", .option) == nil)
        #expect(command(18, "1", .command) == nil)
    }

    private func action(
        _ keyCode: UInt16, _ flags: CGEventFlags = [], repeat isRepeat: Bool = false, enabled: Bool = true
    ) -> ViewerKeyAction {
        InterceptionPolicy.followingAction(
            keyCode: keyCode, characters: nil, flags: flags, isRepeat: isRepeat, systemShortcuts: [], tagsEnabled: enabled
        )
    }

    @Test(arguments: topRow + keypad)
    func followingModeDigits(keyCode: UInt16, number: Int) {
        #expect(action(keyCode) == .tag(number))
    }

    @Test func followingModeAutorepeatAndDisabled() {
        #expect(action(18, repeat: true) == .swallow)      // зажатая цифра щёлкала бы меткой
        #expect(action(18, enabled: false) == .swallow)    // метки выключены — как раньше, до Finder не доходит
        #expect(action(28) == .swallow)                     // 8
        #expect(action(18, .maskShift) == .swallow)
        #expect(action(18, .maskCommand) == .swallow)
    }
}

struct FileTaggerTests {
    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumTagTest-\(UUID().uuidString).png")
        try Data().write(to: url)
        return url
    }

    // Запись — весь список: свой тег файла остаётся, метки складываются, повтор снимает.
    @Test func toggleOnRealFileKeepsOwnTags() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await FileTagger.restore(["Работа"], at: url)
        let first = try await FileTagger.toggle("Красный", at: url)
        #expect(first.before == ["Работа"])
        #expect(first.after == ["Работа", "Красный"])
        let second = try await FileTagger.toggle("Синий", at: url)
        #expect(second.after == ["Работа", "Красный", "Синий"])
        let third = try await FileTagger.toggle("Красный", at: url)
        #expect(third.after == ["Работа", "Синий"])
    }

    // ⌘Z — вернуть список, каким он был до нажатия.
    @Test func restoreReturnsPreviousTags() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await FileTagger.toggle("Красный", at: url)
        let restored = try await FileTagger.restore(result.before, at: url)
        #expect(restored.isEmpty)
    }

    @Test func missingFileFails() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumTagTest-нет-\(UUID().uuidString).png")
        do {
            _ = try await FileTagger.toggle("Красный", at: url)
            Issue.record("метка на несуществующем файле записалась")
        } catch {
            #expect(FileTagger.failure(error) == .missing)
        }
    }

    // Коды из прототипа FinderTagProbe.
    @Test func failuresByCode() {
        #expect(FileTagger.failure(NSError(domain: NSOSStatusErrorDomain, code: -5000)) == .noPermission)
        #expect(FileTagger.failure(NSError(domain: NSOSStatusErrorDomain, code: -61)) == .readOnlyVolume)
        #expect(FileTagger.failure(NSError(domain: NSOSStatusErrorDomain, code: -43)) == .missing)
        #expect(FileTagger.failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)) == .readOnlyVolume)
        #expect(FileTagger.failure(NSError(domain: NSOSStatusErrorDomain, code: -1)) == .other)
    }

    // Имена — семь, по цвету на цифру, без повторов (какие именно — зависит от языка системы).
    @Test func colorNamesAreSevenAndDistinct() async {
        let names = await FileTagger.colorTagNames()
        #expect(names.count == 7)
        #expect(Set(names.compactMap { $0 }).count == names.compactMap { $0 }.count)
    }
}
