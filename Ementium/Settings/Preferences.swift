import Foundation

/// Настройки Ementium: ключи `UserDefaults` и значения по умолчанию — в одном месте.
/// Окно настроек пишет их через `@AppStorage`, остальной код читает через `ViewerPreferences`.
nonisolated enum Preferences {
    enum Key {
        static let interceptionEnabled = "interceptionEnabled"
        static let showMenuBarIcon = "showMenuBarIcon"
        /// Автозапуск включён при первом запуске — дальше решает пользователь.
        static let launchAtLoginConfigured = "launchAtLoginConfigured"
        static let backgroundDimming = "backgroundDimming"
        static let backgroundColor = "backgroundColor"
        static let imageScreenFraction = "imageScreenFraction"
        static let upscaleSmallImages = "upscaleSmallImages"
        /// Запоминать масштаб и место каждой увеличенной картинки до закрытия просмотра.
        static let rememberZoomPerImage = "rememberZoomPerImage"
        static let spaceClosesViewer = "spaceClosesViewer"
        static let animateViewer = "animateViewer"
        /// `⌘⌫` в просмотре перемещает картинку в Корзину (режим «следовать»). По умолчанию выключено.
        static let trashWithCommandDelete = "trashWithCommandDelete"
        /// Угол карточки сведений о снимке (по `⌥`).
        static let infoPanelPosition = "infoPanelPosition"
    }

    static var defaults: [String: Any] { [
        Key.interceptionEnabled: true,
        Key.showMenuBarIcon: true,
        Key.launchAtLoginConfigured: false,
        Key.backgroundDimming: 0.85,
        Key.backgroundColor: "#000000",
        Key.imageScreenFraction: 0.95,
        Key.upscaleSmallImages: false,
        Key.rememberZoomPerImage: true,
        Key.spaceClosesViewer: true,
        Key.animateViewer: true,
        Key.infoPanelPosition: InfoPanelPosition.topRight.rawValue,
        Key.trashWithCommandDelete: false,
    ] }

    static func register(in store: UserDefaults = .standard) {
        store.register(defaults: defaults)
    }
}

/// Настройки окна просмотра — снимок на момент открытия.
nonisolated struct ViewerPreferences: Equatable {
    var dimming: Double
    var color: RGBColor
    /// Доля экрана для «вписать» (большие картинки).
    var screenFraction: Double
    var upscaleSmallImages: Bool
    var rememberZoomPerImage: Bool
    var spaceClosesViewer: Bool
    var animate: Bool
    var infoPosition: InfoPanelPosition
    var trashEnabled: Bool

    init(from store: UserDefaults = .standard) {
        Preferences.register(in: store)
        dimming = min(max(store.double(forKey: Preferences.Key.backgroundDimming), 0), 1)
        color = RGBColor(hex: store.string(forKey: Preferences.Key.backgroundColor) ?? "") ?? .black
        screenFraction = min(max(store.double(forKey: Preferences.Key.imageScreenFraction), 0.5), 1)
        upscaleSmallImages = store.bool(forKey: Preferences.Key.upscaleSmallImages)
        rememberZoomPerImage = store.bool(forKey: Preferences.Key.rememberZoomPerImage)
        spaceClosesViewer = store.bool(forKey: Preferences.Key.spaceClosesViewer)
        animate = store.bool(forKey: Preferences.Key.animateViewer)
        infoPosition = store.string(forKey: Preferences.Key.infoPanelPosition).flatMap(InfoPanelPosition.init) ?? .topRight
        trashEnabled = store.bool(forKey: Preferences.Key.trashWithCommandDelete)
    }
}

/// Угол экрана для карточки сведений о снимке.
nonisolated enum InfoPanelPosition: String, CaseIterable, Equatable {
    case topRight
    case topLeft
    case bottomLeft
    case bottomRight

    var title: String {
        switch self {
        case .topRight: "Справа вверху"
        case .topLeft: "Слева вверху"
        case .bottomLeft: "Слева внизу"
        case .bottomRight: "Справа внизу"
        }
    }
}

/// Цвет фона в виде «#RRGGBB» — так его удобно хранить в `UserDefaults`.
nonisolated struct RGBColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}
