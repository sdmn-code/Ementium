import SwiftUI

@main
struct EmentiumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Окно настроек появится в v0.4. Пока сцена-заглушка нужна только потому,
        // что SwiftUI App обязан объявить хотя бы одну сцену.
        Settings {
            EmptyView()
        }
    }
}
