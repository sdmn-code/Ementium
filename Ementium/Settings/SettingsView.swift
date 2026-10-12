import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel

    @AppStorage(Preferences.Key.interceptionEnabled) private var interceptionEnabled = true
    @AppStorage(Preferences.Key.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Preferences.Key.backgroundDimming) private var dimming = 0.85
    @AppStorage(Preferences.Key.backgroundColor) private var colorHex = "#000000"
    @AppStorage(Preferences.Key.imageScreenFraction) private var screenFraction = 0.95
    @AppStorage(Preferences.Key.upscaleSmallImages) private var upscaleSmallImages = false
    @AppStorage(Preferences.Key.rememberZoomPerImage) private var rememberZoomPerImage = true
    @AppStorage(Preferences.Key.spaceClosesViewer) private var spaceClosesViewer = true
    @AppStorage(Preferences.Key.animateViewer) private var animateViewer = true
    @AppStorage(Preferences.Key.infoPanelPosition) private var infoPosition = InfoPanelPosition.topRight.rawValue

    var body: some View {
        Form {
            if !model.isAccessibilityGranted {
                permissionSection
            } else if model.justGranted {
                Section {
                    Label("Готово: выделите картинку в Finder и нажмите Пробел.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            generalSection
            viewerSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Разрешение

    private var permissionSection: some View {
        Section("Разрешение") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Нужен «Универсальный доступ»", systemImage: "hand.raised.fill")
                    .font(.headline)
                Text("""
                Чтобы открывать картинки по Пробелу вместо Quick Look, Ementium перехватывает Пробел в Finder \
                и читает, какой файл выделен. Без разрешения «Универсальный доступ» macOS этого не позволит. \
                Ementium ничего не отправляет в сеть и не записывает нажатия клавиш.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Разрешить") { model.onRequestAccessibility() }
                        .buttonStyle(.borderedProminent)
                    Button("Открыть настройки доступа") { model.onOpenAccessibilitySettings() }
                }
                Text("После выдачи доступа перехват включится сам, перезапускать Ementium не нужно.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Основные

    private var generalSection: some View {
        Section("Основные") {
            Toggle("Перехватывать Пробел в Finder", isOn: $interceptionEnabled)
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if model.loginItemNeedsApproval {
                HStack {
                    Text("macOS ждёт подтверждения в «Объектах входа»")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Открыть") { LoginItem.openLoginItemsSettings() }
                }
            }
            Toggle("Показывать иконку в строке меню", isOn: $showMenuBarIcon)
            HStack {
                Spacer()
                Button("Выйти из Ementium") { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - Просмотр

    private var viewerSection: some View {
        Section("Просмотр") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Затемнение фона") {
                        HStack {
                            Slider(value: $dimming, in: 0...1)
                            Text("\(Int((dimming * 100).rounded())) %")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    ColorPicker("Цвет фона", selection: colorBinding, supportsOpacity: false)
                }
                backgroundSample
            }
            LabeledContent("Размер изображения на экране") {
                HStack {
                    Slider(value: $screenFraction, in: 0.5...1)
                    Text("\(Int((screenFraction * 100).rounded())) %")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("Увеличивать маленькие картинки до размера экрана", isOn: $upscaleSmallImages)
            Toggle("Запоминать масштаб каждой картинки", isOn: $rememberZoomPerImage)
            Toggle("Пробел закрывает просмотр", isOn: $spaceClosesViewer)
            Toggle("Плавное появление и исчезновение", isOn: $animateViewer)
            Picker("Сведения о снимке (удерживайте ⌥)", selection: $infoPosition) {
                ForEach(InfoPanelPosition.allCases, id: \.rawValue) { position in
                    Text(position.title).tag(position.rawValue)
                }
            }
        }
    }

    /// Образец: «рабочий стол» под фоном с выбранными цветом и затемнением и «картинка» по центру.
    private var backgroundSample: some View {
        ZStack {
            LinearGradient(colors: [.blue, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            backgroundColor.opacity(dimming)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray)
                .frame(width: 56 * screenFraction, height: 38 * screenFraction)
        }
        .frame(width: 96, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        .accessibilityLabel("Образец фона")
    }

    private var backgroundColor: Color {
        let rgb = RGBColor(hex: colorHex) ?? .black
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { backgroundColor },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                colorHex = RGBColor(
                    red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)
                ).hex
            }
        )
    }
}
