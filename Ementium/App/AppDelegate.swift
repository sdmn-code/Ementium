import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewer = ViewerWindowController()
    private let log = Logger(subsystem: "io.github.sdmn-code.Ementium", category: "app")

    // `open -a Ementium файл…` и «Открыть в программе» в Finder приходят сюда —
    // и при запуске, и в уже работающий процесс.
    func application(_ application: NSApplication, open urls: [URL]) {
        log.info("Открыть \(urls.count) файл(ов): \(urls.map(\.lastPathComponent), privacy: .private)")
        viewer.show(urls: urls)
    }
}
