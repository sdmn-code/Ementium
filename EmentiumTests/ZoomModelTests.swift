import CoreGraphics
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

    @Test func nextImageResetsOrKeepsScale() {
        var zoom = ZoomModel(imageSize: CGSize(width: 4000, height: 2000), viewSize: screen)
        zoom.zoomIn()
        zoom.zoomIn()  // 100 %
        zoom.pan(by: CGVector(dx: 100, dy: 0))
        var reset = zoom
        reset.replaceImage(size: CGSize(width: 3000, height: 3000), keepScale: false)
        #expect(reset.isFit)
        #expect(reset.offset == .zero)
        zoom.replaceImage(size: CGSize(width: 3000, height: 3000), keepScale: true)
        #expect(zoom.scale == 1)
        #expect(zoom.offset == .zero)
    }

    // Крошечная картинка, растянутая до экрана, — это «вписать» в тысячи процентов, а не выбранный масштаб:
    // следующая большая должна открыться вписанной, а не с увеличением 800 %.
    @Test func fitStaysFitWhenKeepingScale() {
        var zoom = ZoomModel(imageSize: CGSize(width: 16, height: 16), viewSize: screen, upscalesSmallImages: true)
        #expect(zoom.isFit)
        zoom.replaceImage(size: CGSize(width: 6000, height: 4000), keepScale: true)
        #expect(zoom.isFit)
        #expect(zoom.scale < 1)
    }
}
