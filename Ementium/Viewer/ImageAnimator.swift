import Foundation
import IOSurface

/// Какой кадр показывать следующим и когда остановиться. Чистая логика — покрыта тестами.
nonisolated struct AnimationSchedule: Equatable {
    let frameCount: Int
    /// Сколько раз проиграть: 0 — бесконечно.
    let loopCount: Int
    private(set) var index = 0
    private(set) var plays = 0

    init(frameCount: Int, loopCount: Int) {
        self.frameCount = frameCount
        self.loopCount = max(0, loopCount)
    }

    /// Следующий кадр или `nil`, если анимация отыграла положенное число раз (тогда на экране остаётся
    /// последний кадр, как в браузерах).
    mutating func advance() -> Int? {
        guard frameCount > 1 else { return nil }
        if index + 1 < frameCount {
            index += 1
            return index
        }
        plays += 1
        if loopCount > 0, plays >= loopCount { return nil }
        index = 0
        return 0
    }
}

/// Проигрывает анимацию (GIF, APNG, WebP, HEICS, AVIF): кадры декодирует сервис EmentiumDecoder — разбор
/// файла не попадает в процесс с «Универсальным доступом», — задержки — из файла, по кругу без остановки.
/// Следующий кадр запрашивается, пока показывается текущий. Первый кадр уже на экране (из кэша).
final class ImageAnimator {
    private var task: Task<Void, Never>?

    /// Запускает анимацию `url`, останавливая прежнюю. `onFrame` — на главном потоке.
    func start(_ url: URL, maxPixelSize: Int, onFrame: @escaping (IOSurface) -> Void) {
        stop()
        task = Task {
            let client = DecoderClient.shared
            guard let animation = try? await client.openAnimation(url), animation.frameCount > 1 else { return }
            defer { client.closeAnimation(animation) }
            // Всегда по кругу, как системный аниматор и Quick Look: число повторов в файле ненадёжно — ImageIO
            // сообщает `LoopCount = 1` и тогда, когда его в файле нет (проверено), и такие анимации останавливались.
            var schedule = AnimationSchedule(frameCount: animation.frameCount, loopCount: 0)
            // Кадр 0 уже на экране (из кэша); задержки всех кадров пришли вместе с открытием.
            var delay = animation.delays[0]
            while !Task.isCancelled, let nextIndex = schedule.advance() {
                let shownAt = ContinuousClock.now
                async let upcoming = client.frame(animation, index: nextIndex, maxPixelSize: maxPixelSize)
                // Ждём остаток задержки текущего кадра — декодирование следующего идёт параллельно.
                let wait = Duration.seconds(delay) - shownAt.duration(to: .now)
                if wait > .zero { try? await Task.sleep(for: wait) }
                // Кадр не пришёл (сервис перезапущен — токен протух) — остаёмся на текущем кадре.
                guard !Task.isCancelled, let frame = try? await upcoming else { return }
                onFrame(frame.surface)
                delay = animation.delays[nextIndex]
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
