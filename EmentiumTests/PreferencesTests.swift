import CoreGraphics
import Foundation
import Testing
@testable import Ementium

/// Каждый тест — на своём изолированном хранилище, чтобы не трогать настройки Саши.
final class PreferencesTests {
    private let suiteName = "EmentiumTests-\(UUID().uuidString)"
    private let store: UserDefaults

    init() {
        store = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        store.removePersistentDomain(forName: suiteName)
    }

    @Test func defaultsMatchTheSpec() {
        let viewer = ViewerPreferences(from: store)
        #expect(viewer.dimming == 0.85)
        #expect(viewer.color == .black)
        #expect(viewer.screenFraction == 0.95)
        #expect(!viewer.upscaleSmallImages)
        #expect(viewer.rememberZoomPerImage)
        #expect(viewer.infoPosition == .topRight)
        #expect(!viewer.trashEnabled)  // удаление по ⌘⌫ — только если включить
        #expect(viewer.spaceClosesViewer)
        #expect(viewer.animate)
        #expect(viewer.tags)  // метки клавишами 1–7 — включены
        #expect(viewer.slideshowInterval == 4)
        #expect(!viewer.slideshowLoops)
        #expect(store.bool(forKey: Preferences.Key.interceptionEnabled))
        #expect(store.bool(forKey: Preferences.Key.showMenuBarIcon))
    }

    @Test func storedValuesAreReadAndClamped() {
        store.set(0.4, forKey: Preferences.Key.backgroundDimming)
        store.set("#336699", forKey: Preferences.Key.backgroundColor)
        store.set(0.2, forKey: Preferences.Key.imageScreenFraction)  // меньше 50 % нельзя
        store.set(false, forKey: Preferences.Key.spaceClosesViewer)
        let viewer = ViewerPreferences(from: store)
        #expect(viewer.dimming == 0.4)
        #expect(viewer.color == RGBColor(hex: "#336699"))
        #expect(viewer.screenFraction == 0.5)
        #expect(!viewer.spaceClosesViewer)
    }

    // Интервал слайд-шоу — 2–15 с, что бы ни лежало в настройках.
    @Test func slideshowIntervalIsClamped() {
        store.set(1, forKey: Preferences.Key.slideshowInterval)
        #expect(ViewerPreferences(from: store).slideshowInterval == 2)
        store.set(60, forKey: Preferences.Key.slideshowInterval)
        #expect(ViewerPreferences(from: store).slideshowInterval == 15)
        store.set(7, forKey: Preferences.Key.slideshowInterval)
        store.set(true, forKey: Preferences.Key.slideshowLoops)
        let viewer = ViewerPreferences(from: store)
        #expect(viewer.slideshowInterval == 7)
        #expect(viewer.slideshowLoops)
    }

    @Test func unknownInfoPositionFallsBackToTopRight() {
        store.set("middle", forKey: Preferences.Key.infoPanelPosition)
        #expect(ViewerPreferences(from: store).infoPosition == .topRight)
        store.set("bottomLeft", forKey: Preferences.Key.infoPanelPosition)
        #expect(ViewerPreferences(from: store).infoPosition == .bottomLeft)
    }

    @Test func brokenColorFallsBackToBlack() {
        store.set("not a color", forKey: Preferences.Key.backgroundColor)
        #expect(ViewerPreferences(from: store).color == .black)
    }
}

struct RGBColorTests {
    @Test func hexRoundTrip() {
        let color = RGBColor(hex: "#1A2B3C")
        #expect(color?.hex == "#1A2B3C")
        #expect(RGBColor(hex: "1a2b3c")?.hex == "#1A2B3C")
    }

    @Test(arguments: ["", "#12345", "#GGGGGG", "#1234567"])
    func invalidHexIsRejected(hex: String) {
        #expect(RGBColor(hex: hex) == nil)
    }

    @Test func componentsAreClamped() {
        #expect(RGBColor(red: 2, green: -1, blue: 0.5).hex == "#FF0080")
    }
}

struct ZoomFitOptionsTests {
    private let screen = CGSize(width: 1000, height: 800)

    // «Размер изображения на экране» 95 %: большая картинка вписывается в 95 % экрана.
    @Test func largeImageFitsIntoFractionOfTheScreen() {
        let zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen, fitFraction: 0.95)
        #expect(zoom.imageRect.width == 950)
    }

    // Маленькая картинка доля экрана не трогает — без увеличения она остаётся 100 %.
    @Test func smallImageStaysActualSizeByDefault() {
        let zoom = ZoomModel(imageSize: CGSize(width: 100, height: 100), viewSize: screen, fitFraction: 0.95)
        #expect(zoom.scale == 1)
    }

    @Test func smallImageIsUpscaledWhenEnabled() {
        let zoom = ZoomModel(
            imageSize: CGSize(width: 100, height: 100), viewSize: screen, fitFraction: 0.95, upscalesSmallImages: true
        )
        #expect(zoom.imageRect.height == 760)  // 95 % от 800
        #expect(zoom.isFit)
    }

    // Крошечная картинка, растянутая больше 800 %, — «вписать» и есть предел, без скачков.
    @Test func tinyUpscaledImageCannotGoBeyondFit() {
        var zoom = ZoomModel(
            imageSize: CGSize(width: 16, height: 16), viewSize: screen, upscalesSmallImages: true
        )
        let fit = zoom.scale
        #expect(fit == 50)
        zoom.zoomIn()
        #expect(zoom.scale == fit)
        zoom.zoomOut()
        #expect(zoom.isFit)
    }

    @Test func changingOptionsKeepsFitAsFit() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        zoom.setFitOptions(fraction: 0.5, upscalesSmallImages: false)
        #expect(zoom.isFit)
        #expect(zoom.imageRect.width == 500)
    }
}
