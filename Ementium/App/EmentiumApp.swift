import SwiftUI

@main
struct EmentiumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Пустая сцена нужна только потому, что SwiftUI App обязан объявить хотя бы одну. Настоящее окно
        // настроек — `SettingsWindowController`; пункт меню «Настройки…» (⌘,) подменён, чтобы открывать его,
        // а не эту пустышку (когда Ementium активен — например, открыто окно настроек).
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
