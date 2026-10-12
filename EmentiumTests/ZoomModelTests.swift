import CoreGraphics
import Foundation
import Testing
@testable import Ementium

struct ZoomModelTests {
    private let screen = CGSize(width: 1000, height: 800)

    @Test func largeImageFitsAndSmallIsNotUpscaled() {
        #expect(ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen).scale == 0.25)
        let small = ZoomModel(imageSize: CGSize(width: 100, height: 100), viewSize: screen)
        #expect(small.scale == 1)
        #expect(small.imageRect == CGRect(x: 450, y: 350, width: 100, height: 100))
    }

    // + и - идут по уровням, начиная от «вписать»; меньше «вписать» не уменьшаем.
    @Test func levelsFromFit() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)  // вписать = 25 %
        var seen: [CGFloat] = []
        for _ in 0..<6 {
            zoom.zoomIn()
            seen.append(zoom.scale)
        }
        #expect(seen == [0.5, 1, 2, 4, 8, 8])
        zoom.zoomOut()
        #expect(zoom.scale == 4)
        for _ in 0..<5 { zoom.zoomOut() }
        #expect(zoom.isFit)
        #expect(zoom.label == "Вписать")
    }

    // Уровни ниже «вписать» пропускаются: картинка, вписанная на 60 %, сразу идёт на 100 %.
    @Test func levelsBelowFitAreSkipped() {
        var zoom = ZoomModel(imageSize: CGSize(width: 1000 / 0.6, height: 100), viewSize: screen)
        #expect(abs(zoom.scale - 0.6) < 0.001)
        zoom.zoomIn()
        #expect(zoom.scale == 1)
        zoom.zoomOut()
        #expect(zoom.isFit)
    }

    // Масштаб в точке: точка картинки под курсором остаётся под курсором.
    @Test func anchorPointStaysInPlace() {
        var zoom = ZoomModel(imageSize: CGSize(width: 2000, height: 1600), viewSize: screen)  // вписать = 50 %
        let anchor = CGPoint(x: 800, y: 600)
        let before = zoom.imageRect
        let fraction = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
        zoom.zoomIn(around: anchor)
        let after = zoom.imageRect
        #expect(abs(after.minX + fraction.x * after.width - anchor.x) <= 1)
        #expect(abs(after.minY + fraction.y * after.height - anchor.y) <= 1)
    }

    // Края увеличенной картинки не уходят внутрь экрана.
    @Test func panIsClampedToEdges() {
        var zoom = ZoomModel(imageSize: CGSize(width: 2000, height: 1600), viewSize: screen)
        zoom.zoomIn()  // 100 %: 2000×1600 на экране 1000×800
        zoom.pan(by: CGVector(dx: 5000, dy: -5000))
        let rect = zoom.imageRect
        #expect(rect.minX == 0)
        #expect(rect.maxY == 800)
    }

    // Картинка меньше экрана по одной стороне — по этой стороне всегда по центру.
    @Test func narrowSideStaysCentered() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 400), viewSize: screen)  // вписать = 25 %
        zoom.zoomIn()  // 50 %: 2000×200
        zoom.pan(by: CGVector(dx: 0, dy: 300))
        #expect(zoom.imageRect.midY == 400)
        #expect(zoom.canPan)
    }

    @Test func fitImageCannotPan() {
        let zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        #expect(!zoom.canPan)
    }

    @Test func smartZoomTogglesFitAndActualSize() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        zoom.toggleSmartZoom(at: CGPoint(x: 500, y: 400))
        #expect(zoom.scale == 1)
        zoom.toggleSmartZoom(at: CGPoint(x: 500, y: 400))
        #expect(zoom.isFit)
    }

    // Для маленькой картинки «вписать» уже 100 % — умное увеличение даёт 200 %.
    @Test func smartZoomOnSmallImageDoubles() {
        var zoom = ZoomModel(imageSize: CGSize(width: 100, height: 100), viewSize: screen)
        zoom.toggleSmartZoom(at: CGPoint(x: 500, y: 400))
        #expect(zoom.scale == 2)
    }

    @Test func pinchIsClampedBetweenFitAndMax() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        zoom.magnify(by: -0.9, around: CGPoint(x: 500, y: 400))
        #expect(zoom.isFit)
        for _ in 0..<100 { zoom.magnify(by: 0.5, around: CGPoint(x: 500, y: 400)) }
        #expect(zoom.scale == ZoomModel.maxScale)
        #expect(zoom.label == "800 %")
    }

    // Масштаб с картинки на картинку не переносится: следующая — всегда во «вписать».
    @Test func nextImageIsFit() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        zoom.zoomIn()
        zoom.zoomIn()  // 100 %
        zoom.pan(by: CGVector(dx: 100, dy: 0))
        zoom.replaceImage(size: CGSize(width: 3000, height: 3000))
        #expect(zoom.isFit)
        #expect(zoom.offset == .zero)
    }
}

struct ZoomMemoryTests {
    private let screen = CGSize(width: 1000, height: 800)
    private let a = URL(fileURLWithPath: "/tmp/a.jpg")
    private let b = URL(fileURLWithPath: "/tmp/b.jpg")

    private func zoomed(scale steps: Int, pan: CGVector = .zero) -> ZoomModel {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        for _ in 0..<steps { zoom.zoomIn() }
        zoom.pan(by: pan)
        return zoom
    }

    // Увеличили A, ушли — вернулись: тот же масштаб и то же место.
    @Test func zoomedImageIsRestored() {
        var memory = ZoomMemory()
        let zoom = zoomed(scale: 3, pan: CGVector(dx: 120, dy: -40))  // 200 %
        memory.remember(zoom, for: a)
        #expect(memory.placement(for: a) == .restore(scale: 2, offset: CGPoint(x: 120, y: -40)))
        #expect(memory.placement(for: b) == .fit)
    }

    // Вернули A во «вписать» вручную — запись забыта.
    @Test func fitImageIsForgotten() {
        var memory = ZoomMemory()
        memory.remember(zoomed(scale: 3), for: a)
        var back = zoomed(scale: 3)
        back.zoomToFit()
        memory.remember(back, for: a)
        #expect(memory.count == 0)
        #expect(memory.placement(for: a) == .fit)
    }

    // Настройка «Запоминать масштаб каждой картинки» выключена — всё во «вписать», ничего не копится.
    @Test func disabledMemoryAlwaysFits() {
        var memory = ZoomMemory()
        memory.remember(zoomed(scale: 4), for: a)
        memory.isEnabled = false
        #expect(memory.placement(for: a) == .fit)
        memory.remember(zoomed(scale: 4), for: b)
        #expect(memory.count == 0)
        memory.isEnabled = true
        #expect(memory.placement(for: a) == .fit)  // выключение стирает записи
    }

    @Test func forgetClearsEverything() {
        var memory = ZoomMemory()
        memory.remember(zoomed(scale: 3), for: a)
        memory.remember(zoomed(scale: 4), for: b)
        memory.forget()
        #expect(memory.count == 0)
    }

    @Test func restoreWithinLimits() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        zoom.restore(scale: 2, offset: CGPoint(x: 100, y: 0))
        #expect(zoom.scale == 2)
        #expect(zoom.offset == CGPoint(x: 100, y: 0))

        // Больше предела — 800 %; сдвиг — не дальше края картинки.
        zoom.restore(scale: 100, offset: CGPoint(x: 99_999, y: -99_999))
        #expect(zoom.scale == ZoomModel.maxScale)
        #expect(zoom.offset == CGPoint(x: (4000 * 8 - 1000) / 2, y: -(2000 * 8 - 800) / 2))

        // Меньше «вписать» (другой экран, другая доля) — «вписать» по центру.
        zoom.restore(scale: 0.01, offset: CGPoint(x: 50, y: 50))
        #expect(zoom.isFit)
        #expect(zoom.offset == .zero)
    }
}
