import AppKit
import SwiftUI

/// Панели окна настроек — вкладки в панели инструментов (HIG Settings): заголовок окна — имя панели,
/// у каждой свой размер, последняя открытая запоминается.
enum SettingsPane: Int, CaseIterable {
    case general
    case viewer
    case controls
    case about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .viewer: String(localized: "Viewer")
        case .controls: String(localized: "Controls")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .viewer: "photo"
        case .controls: "keyboard"
        case .about: "info.circle"
        }
    }
}

private extension View {
    /// Общий вид панелей: системная сгруппированная форма — Liquid Glass подхватывается сам. Переключатели —
    /// явно: внутри `LabeledContent` переключатель иначе мог бы стать флажком.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Основные

/// Разрешение (пока его нет), главный выключатель, автозапуск, иконка, выход.
struct GeneralPane: View {
    @Bindable var model: SettingsModel

    @AppStorage(Preferences.Key.interceptionEnabled) private var interceptionEnabled = true
    @AppStorage(Preferences.Key.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some View {
        Form {
            if !model.isAccessibilityGranted {
                permissionSection
            } else if model.justGranted {
                Section {
                    // Зелёная — только галочка: зелёный текст на светлом фоне читается плохо.
                    Label {
                        Text("Done. In Finder, select an image and press Space. Esc closes, arrows browse.")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            Section {
                Toggle(isOn: $interceptionEnabled) {
                    Text("Open images with Space in Finder")
                    Text("Other files open in Quick Look as usual.")
                }
                // Пока macOS ждёт подтверждения, автозапуск включён по воле пользователя — переключатель не «отскакивает».
                Toggle(isOn: Binding(
                    get: { model.launchAtLogin || model.loginItemNeedsApproval },
                    set: { model.setLaunchAtLogin($0) }
                )) {
                    Text("Open at Login")
                    if model.loginItemNeedsApproval {
                        Text("Waiting for your approval in System Settings.")
                    }
                }
                if model.loginItemNeedsApproval {
                    Button("Open System Settings…") { LoginItem.openLoginItemsSettings() }
                }
                // Пояснение — всегда: так высота «Основных» не прыгает от щелчка по переключателю.
                Toggle(isOn: $showMenuBarIcon) {
                    Text("Show icon in menu bar")
                    Text("Without the icon, open Settings by launching Ementium again.")
                }
            }
            // Выход — действие, а не настройка: своя карточка с объяснением, что приложение живёт в фоне.
            Section {
                LabeledContent("Ementium runs in the background") {
                    Button("Quit Ementium") { NSApp.terminate(nil) }
                }
            } footer: {
                Text("Esc closes only the viewer. After quitting, Space opens Quick Look again.")
            }
        }
        .settingsForm()
    }

    // Одна главная кнопка вызывает системный запрос; название пункта в «Системных настройках» не пишем —
    // в macOS 27 он переименован, а кнопка ведёт прямо в него.
    private var permissionSection: some View {
        Section("Permission") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ementium opens images with Space in Finder. For that, it needs to notice Space and see which file is selected — macOS allows this only with your permission. Ementium works only in Finder, sends nothing over the network and doesn't record keystrokes.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. macOS will show a request.")
                    Text("2. In System Settings, turn on Ementium.")
                    Text("3. That's it — no need to restart Ementium.")
                }
                .foregroundStyle(.secondary)
                HStack {
                    Button("Continue…") { model.onRequestAccessibility() }
                        .buttonStyle(.borderedProminent)
                    Button("Open System Settings…") { model.onOpenAccessibilitySettings() }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Просмотр

/// Как выглядит просмотр: образец сверху, фон, размер, сведения о снимке.
struct ViewerPane: View {
    @AppStorage(Preferences.Key.backgroundDimming) private var dimming = 0.85
    @AppStorage(Preferences.Key.backgroundColor) private var colorHex = "#000000"
    @AppStorage(Preferences.Key.imageScreenFraction) private var screenFraction = 0.95
    @AppStorage(Preferences.Key.upscaleSmallImages) private var upscaleSmallImages = false
    @AppStorage(Preferences.Key.animateViewer) private var animateViewer = true
    @AppStorage(Preferences.Key.infoPanelPosition) private var infoPosition = InfoPanelPosition.topRight.rawValue
    @AppStorage(Preferences.Key.liveText) private var liveText = true

    var body: some View {
        Form {
            // Образец зависит от затемнения, цвета и размера — поэтому над всеми тремя, а не рядом с двумя.
            Section {
                BackgroundSample(color: backgroundColor, dimming: dimming, fraction: screenFraction)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            Section("Background") {
                PercentSlider(title: "Background dimming", value: $dimming, range: 0...1)
                LabeledContent("Background color") {
                    BackgroundColorPicker(hex: $colorHex)
                        .fixedSize()
                }
                Toggle("Fade in and out", isOn: $animateViewer)
            }
            Section("Size") {
                PercentSlider(
                    title: "Large image size", description: "Share of the screen for images that don't fit.",
                    value: $screenFraction, range: 0.5...1
                )
                Toggle(isOn: $upscaleSmallImages) {
                    Text("Enlarge small images")
                    Text("Stretch them to the large image size; otherwise they open at actual size.")
                }
            }
            // Только распознавание: «Поделиться» по `⌘` работает и без него.
            Section("Live Text") {
                Toggle(isOn: $liveText) {
                    Text("Recognize text and objects")
                    Text("Hold ⌘ in the viewer to select text and look up objects.")
                }
            }
            Section {
                Picker(selection: $infoPosition) {
                    ForEach(InfoPanelPosition.allCases, id: \.rawValue) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    Text("Position")
                    Text("Hold ⌥ in the viewer to show it.")
                }
            } header: {
                Text("Photo info")
            } footer: {
                Text("Changes apply the next time the viewer opens.")
            }
        }
        .settingsForm()
    }

    private var backgroundColor: Color {
        let rgb = RGBColor(hex: colorHex) ?? .black
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// Колодец цвета фона. Палитра открывается впереди и с фокусом: щелчок, который её открыл, мог только что попросить
/// активацию Ementium (см. `SettingsPanel`), и без `orderFrontRegardless` она ушла бы под окна активного приложения.
/// Второй щелчок закрывает палитру: стандартный колодец лишь отвязывается от неё, и палитра остаётся открытой
/// с ползунком непрозрачности, которой у фона нет.
final class BackgroundColorWell: NSColorWell {
    /// До какого момента открытая палитра ждёт активации Ementium, чтобы получить фокус (см. `SettingsWindowController`).
    static var paletteFocusDeadline = Date.distantPast

    override func activate(_ exclusive: Bool) {
        super.activate(exclusive)
        let panel = NSColorPanel.shared
        panel.orderFrontRegardless()
        panel.makeKey()
        if !NSRunningApplication.current.isActive { Self.paletteFocusDeadline = Date().addingTimeInterval(1) }
    }

    // Колодец отвязался — вторым щелчком, сменой вкладки (AppKit отключает колодец, снятый с окна) или закрытием
    // самой палитры. Без него палитра не нужна: скрываем (`orderOut`, а не `close` — та и вызывает этот метод).
    override func deactivate() {
        let wasActive = isActive
        super.deactivate()
        if wasActive, NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
            NSColorPanel.shared.orderOut(nil)
        }
    }
}

/// Цвет фона — свой колодец, а не SwiftUI `ColorPicker`: у того не поменять, как открывается и закрывается палитра.
/// Значение — строка `#RRGGBB` из настроек.
private struct BackgroundColorPicker: NSViewRepresentable {
    @Binding var hex: String

    func makeNSView(context: Context) -> BackgroundColorWell {
        // Не `init(style:)`: он возвращает `NSColorWell`, а не подкласс.
        let well = BackgroundColorWell(frame: .zero)
        well.colorWellStyle = .default
        well.supportsAlpha = false
        // Образец над настройками меняется, пока цвет ведут в палитре, а не после.
        well.isContinuous = true
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        well.setAccessibilityLabel(String(localized: "Background color"))
        return well
    }

    func updateNSView(_ well: BackgroundColorWell, context: Context) {
        context.coordinator.hex = $hex
        let rgb = RGBColor(hex: hex) ?? .black
        // Сравнение — по #RRGGBB: цвет из палитры точнее, и подмена его округлённым дёргала бы палитру.
        guard Self.rgb(of: well.color)?.hex != rgb.hex else { return }
        well.color = NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(hex: $hex) }

    static func rgb(of color: NSColor) -> RGBColor? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return RGBColor(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent))
    }

    final class Coordinator: NSObject {
        var hex: Binding<String>

        init(hex: Binding<String>) {
            self.hex = hex
        }

        @objc func colorChanged(_ sender: NSColorWell) {
            guard let rgb = BackgroundColorPicker.rgb(of: sender.color) else { return }
            hex.wrappedValue = rgb.hex
        }
    }
}

/// Образец: «экран» 16:10 с «рабочим столом» под фоном выбранных цвета и затемнения и «снимок» 3:2, вписанный
/// в долю экрана, как в просмотре: при 100 % касается краёв. Для VoiceOver скрыт — значения читают ползунки.
private struct BackgroundSample: View {
    let color: Color
    let dimming: Double
    let fraction: Double

    private static let screen = CGSize(width: 192, height: 120)

    var body: some View {
        let fit = min(Self.screen.width * fraction / 3, Self.screen.height * fraction / 2)
        ZStack {
            LinearGradient(colors: [.blue, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            color.opacity(dimming)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.gray)
                .frame(width: fit * 3, height: fit * 2)
        }
        .frame(width: Self.screen.width, height: Self.screen.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator))
        .accessibilityHidden(true)
    }
}

/// Ползунок «стопкой»: подпись и значение — строкой, ползунок — на всю ширину, поэтому его длина не зависит
/// от длины подписи в переводе. Значение — по локали («85%», «85 %»); VoiceOver читает его у ползунка.
private struct PercentSlider: View {
    let title: LocalizedStringKey
    var description: LocalizedStringKey?
    @Binding var value: Double
    let range: ClosedRange<Double>

    private static let percent = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0))

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: Self.percent)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: $value, in: range) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue(Text(value, format: Self.percent))
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Управление

/// Клавиатура, масштаб и удаление — поведение просмотра.
struct ControlsPane: View {
    @AppStorage(Preferences.Key.spaceClosesViewer) private var spaceClosesViewer = true
    @AppStorage(Preferences.Key.rememberZoomPerImage) private var rememberZoomPerImage = true
    @AppStorage(Preferences.Key.trashWithCommandDelete) private var trashEnabled = false

    var body: some View {
        Form {
            Section("Keyboard") {
                Toggle("Space closes the viewer", isOn: $spaceClosesViewer)
            }
            Section("Zoom") {
                Toggle(isOn: $rememberZoomPerImage) {
                    Text("Remember zoom and rotation for each image")
                    Text("Kept until the viewer closes.")
                }
            }
            // Единственная настройка, которая меняет файлы вне приложения, — отдельно, с описанием, что произойдёт.
            Section {
                Toggle(isOn: $trashEnabled) {
                    Text("Move to Trash with ⌘⌫")
                    Text("The image on screen goes to the Trash through Finder, and the next one opens. Only when it was opened with Space in Finder, not on the Desktop. Undo: ⌘Z in the viewer or later in Finder.")
                }
            } header: {
                Text("Deleting")
            } footer: {
                // Как и «Просмотр», вкладка читается снимком при открытии просмотра.
                Text("Changes apply the next time the viewer opens.")
            }
        }
        .settingsForm()
    }
}

// MARK: - О программе

/// Иконка, версия, ссылки. У агентского приложения нет меню «О программе» — здесь единственное место с версией.
struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(verbatim: "Ementium")
                        .font(.title2.weight(.semibold))
                    Text(Self.version)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Link("Source code on GitHub", destination: URL(string: "https://github.com/sdmn-code/Ementium")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/sdmn-code/Ementium/issues")!)
            } footer: {
                Text("© 2026 Alexander Key. MIT License.")
                    .frame(maxWidth: .infinity)
            }
        }
        .settingsForm()
    }

    /// «1.0 (1)» — версия и номер сборки из Info.plist.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
    }
}
