import Foundation

/// Отдельный поток со своим run loop. На нём живут AXObserver и event tap, чтобы их работа
/// не зависела от главного потока и друг от друга.
nonisolated final class RunLoopThread: @unchecked Sendable {
    // Записывается один раз до выхода из init, дальше только читается.
    private var runLoop: CFRunLoop?

    init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            self.runLoop = CFRunLoopGetCurrent()
            // Run loop без источников сразу завершается — держим его пустым портом.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Выполняет блок на этом потоке.
    func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Подключает источник событий (AXObserver, event tap) к run loop этого потока.
    func add(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopAddSource(runLoop, source, .defaultMode)
    }

    func remove(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }
}
