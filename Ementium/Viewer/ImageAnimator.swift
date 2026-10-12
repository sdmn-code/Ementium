import Foundation
import ImageIO

/// Проигрывает анимацию (GIF, APNG, WebP, HEICS, AVIF) системным `CGAnimateImageAtURLWithBlock`:
/// задержки кадров и число повторов — как записано в файле, кадры декодируются по ходу, а не все сразу.
/// Кадры приходят на главную очередь в исходном размере — их просто подставляют в слой картинки,
/// масштаб и сдвиг не меняются.
final class ImageAnimator {
    /// Флаг остановки для текущего проигрывания: у каждого запуска свой, чтобы кадр старой анимации,
    /// уже стоящий в очереди, не попал на новую картинку.
    private final class Playback {
        var isStopped = false
    }

    private var playback: Playback?

    /// Запускает анимацию `url`, останавливая прежнюю. `onFrame` — на главном потоке.
    func start(_ url: URL, onFrame: @escaping (CGImage) -> Void) {
        stop()
        let current = Playback()
        playback = current
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { _, frame, stop in
            // Кадры приходят на главную очередь.
            MainActor.assumeIsolated {
                if current.isStopped {
                    stop.pointee = true
                    return
                }
                onFrame(frame)
            }
        }
        if status != noErr { playback = nil }
    }

    func stop() {
        playback?.isStopped = true
        playback = nil
    }
}
