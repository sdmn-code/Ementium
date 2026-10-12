import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Ementium

struct InfoHoldTrackerTests {
    // Удерживаешь только ⌥ — через 0,5 с сведения; отпустил — скрыть.
    @Test func plainHoldShowsAndReleaseHides() {
        var hold = InfoHoldTracker()
        #expect(hold.modifiersChanged(.option) == [.startTimer])
        #expect(hold.timerFired() == [.show])
        #expect(hold.state == .shown)
        #expect(hold.modifiersChanged([]) == [.hide])
        #expect(hold.state == .idle)
    }

    @Test func releaseBeforeDelayCancels() {
        var hold = InfoHoldTracker()
        _ = hold.modifiersChanged(.option)
        #expect(hold.modifiersChanged([]) == [.cancelTimer])
        #expect(hold.timerFired() == [])
    }

    // ⌥⌘Пробел и другие сочетания: ничего не мелькает, пока ⌥ не отпустят.
    @Test func secondModifierCancelsUntilRelease() {
        var hold = InfoHoldTracker()
        _ = hold.modifiersChanged(.option)
        #expect(hold.modifiersChanged([.option, .command]) == [.cancelTimer])
        #expect(hold.modifiersChanged(.option) == [])  // ⌘ отпустили, ⌥ всё ещё держат
        #expect(hold.timerFired() == [])
        #expect(hold.modifiersChanged([]) == [])
        #expect(hold.modifiersChanged(.option) == [.startTimer])  // новое нажатие — снова можно
    }

    @Test func optionAddedToAnotherModifierNeverShows() {
        var hold = InfoHoldTracker()
        #expect(hold.modifiersChanged(.command) == [])
        #expect(hold.modifiersChanged([.command, .option]) == [])
        #expect(hold.modifiersChanged(.option) == [])
        #expect(hold.state == .cancelled)
    }

    @Test func keyDuringDelayCancels() {
        var hold = InfoHoldTracker()
        _ = hold.modifiersChanged(.option)
        #expect(hold.keyPressed(isArrow: true) == [.cancelTimer])
        #expect(hold.timerFired() == [])
    }

    // Сведения показаны: ⌥ + стрелки листают, сведения остаются; другая клавиша — скрыть.
    @Test func arrowsKeepShownOtherKeysHide() {
        var hold = InfoHoldTracker()
        _ = hold.modifiersChanged(.option)
        _ = hold.timerFired()
        #expect(hold.keyPressed(isArrow: true) == [])
        #expect(hold.state == .shown)
        #expect(hold.keyPressed(isArrow: false) == [.hide])
        #expect(hold.state == .cancelled)
    }

    @Test func extraModifierWhileShownHides() {
        var hold = InfoHoldTracker()
        _ = hold.modifiersChanged(.option)
        _ = hold.timerFired()
        #expect(hold.modifiersChanged([.option, .shift]) == [.hide])
        #expect(hold.modifiersChanged(.option) == [])
    }

    @Test func resetHidesOrCancels() {
        var shown = InfoHoldTracker()
        _ = shown.modifiersChanged(.option)
        _ = shown.timerFired()
        #expect(shown.reset() == [.hide])
        var arming = InfoHoldTracker()
        _ = arming.modifiersChanged(.option)
        #expect(arming.reset() == [.cancelTimer])
        #expect(arming.state == .idle)
    }

    // Caps Lock, Fn и служебные флаги стрелок — не модификаторы для сведений.
    @Test func serviceFlagsAreIgnored() {
        #expect(HoldModifiers([CGEventFlags.maskAlternate, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad]) == .option)
        #expect(HoldModifiers([NSEvent.ModifierFlags.option, .capsLock, .function]) == .option)
    }
}

struct ImageMetadataTests {
    private let file = ImageMetadata.FileFacts(
        name: "DSC01234.ARW", byteCount: 24_123_456, modified: nil, typeDescription: "Изображение RAW Sony"
    )

    private func key(_ name: CFString) -> String { name as String }

    @Test func fullSetOfFields() {
        let properties: [String: Any] = [
            key(kCGImagePropertyPixelWidth): 6000,
            key(kCGImagePropertyPixelHeight): 4000,
            key(kCGImagePropertyTIFFDictionary): [key(kCGImagePropertyTIFFMake): "SONY", key(kCGImagePropertyTIFFModel): "ILCE-7M3"],
            key(kCGImagePropertyExifAuxDictionary): [key(kCGImagePropertyExifAuxLensModel): "FE 24-70mm F2.8 GM"],
            key(kCGImagePropertyExifDictionary): [
                key(kCGImagePropertyExifDateTimeOriginal): "2025:10:12 14:32:05",
                key(kCGImagePropertyExifFocalLength): 35.0,
                key(kCGImagePropertyExifFNumber): 2.8,
                key(kCGImagePropertyExifExposureTime): 0.004,
                key(kCGImagePropertyExifISOSpeedRatings): [400],
                key(kCGImagePropertyExifExposureBiasValue): -0.3333,
                key(kCGImagePropertyExifFlash): 16,  // не сработала
            ],
            key(kCGImagePropertyGPSDictionary): [
                key(kCGImagePropertyGPSLatitude): 55.75583, key(kCGImagePropertyGPSLatitudeRef): "N",
                key(kCGImagePropertyGPSLongitude): 37.61730, key(kCGImagePropertyGPSLongitudeRef): "E",
            ],
        ]
        #expect(ImageMetadata.lines(properties: properties, file: file, language: .russian) == [
            "DSC01234.ARW",
            "12 октября 2025, 14:32",
            "Изображение RAW Sony · 6000×4000",
            "24,1 МБ",
            "SONY ILCE-7M3",
            "FE 24-70mm F2.8 GM",
            "35 мм  ƒ/2,8  1/250 с",
            "ISO 400  −0,3 EV",
            "55,7558° с. ш., 37,6173° в. д.",
        ])
    }

    // Скриншот, SVG: только файл и дата изменения.
    @Test func noExifOnlyFileFacts() {
        let modified = Date(timeIntervalSince1970: 0)
        let facts = ImageMetadata.FileFacts(name: "screen.png", byteCount: 512, modified: modified, typeDescription: nil)
        let lines = ImageMetadata.lines(properties: [:], file: facts, language: .russian)
        #expect(lines.count == 3)
        #expect(lines[0] == "screen.png")
        #expect(lines[1] == ImageMetadata.formatDate(modified, timeZone: .current, language: .russian))
        #expect(lines[2] == "1 КБ")
    }

    @Test func rotatedImageSwapsSides() {
        let properties: [String: Any] = [
            key(kCGImagePropertyPixelWidth): 6000, key(kCGImagePropertyPixelHeight): 4000, key(kCGImagePropertyOrientation): 6,
        ]
        let facts = ImageMetadata.FileFacts(name: "p.jpg", typeDescription: "JPEG")
        #expect(ImageMetadata.lines(properties: properties, file: facts, language: .russian).contains("JPEG · 4000×6000"))
    }

    @Test(arguments: [
        (0.004, "1/250 с"), (1.0 / 3, "1/3 с"), (0.4, "0,4 с"), (2.0, "2 с"), (1.5, "1,5 с"), (1.0 / 8000, "1/8000 с"),
    ])
    func shutterSpeeds(seconds: Double, expected: String) {
        #expect(ImageMetadata.shutter(seconds, language: .russian) == expected)
    }

    @Test func cameraNameWithoutRepeatedBrand() {
        #expect(ImageMetadata.camera(make: "NIKON CORPORATION", model: "NIKON D750") == "NIKON D750")
        #expect(ImageMetadata.camera(make: "Canon", model: "Canon EOS R5") == "Canon EOS R5")
        #expect(ImageMetadata.camera(make: "Apple", model: "iPhone 15 Pro") == "Apple iPhone 15 Pro")
        #expect(ImageMetadata.camera(make: nil, model: "X100V") == "X100V")
        #expect(ImageMetadata.camera(make: "FUJIFILM", model: nil) == "FUJIFILM")
        #expect(ImageMetadata.camera(make: " ", model: "") == nil)
    }

    // Поправка 0 не показывается, вспышка — только если сработала, юг и запад — словами.
    @Test func exposureDetailsAndSouthWest() {
        let properties: [String: Any] = [
            key(kCGImagePropertyExifDictionary): [
                key(kCGImagePropertyExifExposureBiasValue): 0.0,
                key(kCGImagePropertyExifFlash): 1,
                key(kCGImagePropertyExifISOSpeedRatings): [100],
                key(kCGImagePropertyExifFNumber): 4.0,
            ],
            key(kCGImagePropertyGPSDictionary): [
                key(kCGImagePropertyGPSLatitude): 33.8688, key(kCGImagePropertyGPSLatitudeRef): "S",
                key(kCGImagePropertyGPSLongitude): 151.2093, key(kCGImagePropertyGPSLongitudeRef): "W",
            ],
        ]
        let lines = ImageMetadata.lines(properties: properties, file: ImageMetadata.FileFacts(name: "a.jpg"), language: .russian)
        #expect(lines.contains("ƒ/4"))
        #expect(lines.contains("ISO 100  вспышка"))
        #expect(lines.contains("33,8688° ю. ш., 151,2093° з. д."))
    }

    @Test func fileSizes() {
        #expect(ImageMetadata.fileSize(900, language: .russian) == "1 КБ")
        #expect(ImageMetadata.fileSize(450_000, language: .russian) == "450 КБ")
        #expect(ImageMetadata.fileSize(2_000_000, language: .russian) == "2,0 МБ")
    }

    // Английский: точка, «mm», «s», стороны света буквами, дата по шаблону языка.
    @Test func englishCard() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let properties: [String: Any] = [
            key(kCGImagePropertyExifDictionary): [
                key(kCGImagePropertyExifDateTimeOriginal): "2025:10:12 14:32:05",
                key(kCGImagePropertyExifFocalLength): 35.0,
                key(kCGImagePropertyExifFNumber): 2.8,
                key(kCGImagePropertyExifExposureTime): 0.004,
                key(kCGImagePropertyExifFlash): 1,
            ],
            key(kCGImagePropertyGPSDictionary): [
                key(kCGImagePropertyGPSLatitude): 33.8688, key(kCGImagePropertyGPSLatitudeRef): "S",
                key(kCGImagePropertyGPSLongitude): 151.2093, key(kCGImagePropertyGPSLongitudeRef): "E",
            ],
        ]
        let facts = ImageMetadata.FileFacts(name: "a.jpg", byteCount: 2_500_000)
        let lines = ImageMetadata.lines(properties: properties, file: facts, language: .english)
        #expect(lines.contains("35 mm  ƒ/2.8  1/250 s"))
        #expect(lines.contains("flash"))
        #expect(lines.contains("33.8688° S, 151.2093° E"))
        #expect(lines.contains("2.5 MB"))
        let taken = ImageMetadata.formatDate(Date(timeIntervalSince1970: 1_760_279_520), timeZone: utc, language: .english)
        #expect(taken.contains("October") && taken.contains("2025"))
        #expect(!taken.contains("октября"))
    }

    // Сведения читаются из настоящего файла без декодирования картинки.
    @Test func readsRealFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmentiumInfo-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(
            data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 5.6],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let lines = await ImageMetadata.read(url)
        #expect(lines.first == url.lastPathComponent)
        #expect(lines.contains { $0.hasSuffix("300×200") })
        #expect(lines.contains("ƒ/5,6"))
    }
}

struct OptionArrowTests {
    // Держишь ⌥ (сведения о снимке) и листаешь — в обоих режимах.
    @Test func optionArrowStepsInFollowingMode() {
        func action(_ keyCode: UInt16, _ flags: CGEventFlags) -> ViewerKeyAction {
            InterceptionPolicy.followingAction(keyCode: keyCode, characters: nil, flags: flags, isRepeat: false, systemShortcuts: [])
        }
        #expect(action(124, [.maskAlternate, .maskSecondaryFn, .maskNumericPad]) == .step(.right))
        #expect(action(123, .maskAlternate) == .step(.left))
        #expect(action(124, [.maskAlternate, .maskCommand]) == .swallow)
    }

    @Test func optionArrowBrowsesOwnList() {
        #expect(ViewerCommand(keyCode: 124, characters: nil, modifiers: .option) == .next)
        #expect(ViewerCommand(keyCode: 126, characters: nil, modifiers: [.option, .function, .numericPad]) == .previous)
        #expect(ViewerCommand(keyCode: 124, characters: nil, modifiers: [.option, .shift]) == nil)
    }
}
