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
    @AppStorage(Preferences.Key.trashWithCommandDelete) private var trashEnabled = false

    var body: some View {
        Form {
            if !model.isAccessibilityGranted {
                permissionSection
            } else if model.justGranted {
                Section {
                    Label("Done: select an image in Finder and press Space.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            generalSection
            viewerSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Разрешение

    private var permissionSection: some View {
        Section("Permission") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Accessibility access needed", systemImage: "hand.raised.fill")
                    .font(.headline)
                Text("To open images with Space instead of Quick Look, Ementium intercepts Space in Finder and reads which file is selected. macOS won't allow this without Accessibility permission. Ementium sends nothing over the network and doesn't record keystrokes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Allow") { model.onRequestAccessibility() }
                        .buttonStyle(.borderedProminent)
                    Button("Open Accessibility Settings") { model.onOpenAccessibilitySettings() }
                }
                Text("Once access is granted, interception starts by itself — no need to restart Ementium.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Основные

    private var generalSection: some View {
        Section("General") {
            Toggle("Intercept Space in Finder", isOn: $interceptionEnabled)
            Toggle("Open at Login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if model.loginItemNeedsApproval {
                HStack {
                    Text("macOS is waiting for approval in Login Items")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open") { LoginItem.openLoginItemsSettings() }
                }
            }
            Toggle("Show icon in menu bar", isOn: $showMenuBarIcon)
            HStack {
                Spacer()
                Button("Quit Ementium") { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - О программе

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Ementium", value: Self.version)
            Link("Source code on GitHub", destination: URL(string: "https://github.com/sdmn-code/Ementium")!)
            Text("© 2026 Alexander Key. MIT License.")
                .foregroundStyle(.secondary)
        }
    }

    /// «1.0 (1)» — версия и номер сборки из Info.plist.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
    }

    // MARK: - Просмотр

    private var viewerSection: some View {
        Section("Viewer") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Background dimming") {
                        HStack {
                            Slider(value: $dimming, in: 0...1)
                            Text("\(Int((dimming * 100).rounded())) %")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    ColorPicker("Background color", selection: colorBinding, supportsOpacity: false)
                }
                backgroundSample
            }
            LabeledContent("Image size on screen") {
                HStack {
                    Slider(value: $screenFraction, in: 0.5...1)
                    Text("\(Int((screenFraction * 100).rounded())) %")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Toggle("Enlarge small images to fit the screen", isOn: $upscaleSmallImages)
            Toggle("Remember zoom for each image", isOn: $rememberZoomPerImage)
            Toggle("Space closes the viewer", isOn: $spaceClosesViewer)
            Toggle("Fade in and out", isOn: $animateViewer)
            Picker("Photo info (hold ⌥)", selection: $infoPosition) {
                ForEach(InfoPanelPosition.allCases, id: \.rawValue) { position in
                    Text(position.title).tag(position.rawValue)
                }
            }
            Toggle(isOn: $trashEnabled) {
                Text("⌘⌫ moves to Trash")
                Text("When the image was opened with Space in Finder. Undo with ⌘Z while the viewer is open, or ⌘Z in Finder.")
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
        .accessibilityLabel("Background sample")
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
