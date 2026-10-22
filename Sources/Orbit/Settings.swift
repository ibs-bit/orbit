import AppKit
import SwiftUI
import ServiceManagement

enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option, function
    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .function: return .function
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .function: return "fn"
        }
    }

    var title: String {
        switch self {
        case .shift: return "Shift ⇧"
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        case .option: return "Option ⌥"
        case .function: return "Function fn"
        }
    }
}

enum WheelMode: String, CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    var key: ModifierKey {
        get {
            switch self {
            case .convert: return Preferences.convertKey
            case .tools: return Preferences.toolsKey
            case .actions: return Preferences.actionsKey
            }
        }
    }
}

enum Preferences {
    static let defaults = UserDefaults.standard

    static var convertKey: ModifierKey {
        get { ModifierKey(rawValue: defaults.string(forKey: "convertKey") ?? "") ?? .shift }
        set { defaults.set(newValue.rawValue, forKey: "convertKey") }
    }
    static var toolsKey: ModifierKey {
        get { ModifierKey(rawValue: defaults.string(forKey: "toolsKey") ?? "") ?? .command }
        set { defaults.set(newValue.rawValue, forKey: "toolsKey") }
    }
    static var actionsKey: ModifierKey {
        get { ModifierKey(rawValue: defaults.string(forKey: "actionsKey") ?? "") ?? .control }
        set { defaults.set(newValue.rawValue, forKey: "actionsKey") }
    }
    static var outputLocation: OutputLocation {
        get { OutputLocation(rawValue: defaults.string(forKey: "outputLocation") ?? "") ?? .sameFolder }
        set { defaults.set(newValue.rawValue, forKey: "outputLocation") }
    }
    static var revealAfterFinish: Bool {
        get { defaults.object(forKey: "revealAfterFinish") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "revealAfterFinish") }
    }
    static var playSound: Bool {
        get { defaults.object(forKey: "playSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSound") }
    }

    /// Which wheel the current modifier flags ask for, if any.
    static func mode(for flags: NSEvent.ModifierFlags) -> WheelMode? {
        for mode in WheelMode.allCases where flags.contains(mode.key.flag) { return mode }
        return nil
    }
}

// MARK: - Settings UI

struct SettingsView: View {
    @AppStorage("convertKey") private var convertKey = ModifierKey.shift.rawValue
    @AppStorage("toolsKey") private var toolsKey = ModifierKey.command.rawValue
    @AppStorage("actionsKey") private var actionsKey = ModifierKey.control.rawValue
    @AppStorage("outputLocation") private var outputLocation = OutputLocation.sameFolder.rawValue
    @AppStorage("revealAfterFinish") private var revealAfterFinish = false
    @AppStorage("playSound") private var playSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var accessibility = AXIsProcessTrusted()
    @State private var backendRefresh = 0

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            dependencies.tabItem { Label("Dependencies", systemImage: "shippingbox") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 400)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibility = AXIsProcessTrusted()
        }
    }

    private var general: some View {
        Form {
            Section("Hold while dragging a file") {
                keyPicker("Convert wheel", $convertKey)
                keyPicker("Tools wheel", $toolsKey)
                keyPicker("Actions wheel", $actionsKey)
                if Set([convertKey, toolsKey, actionsKey]).count < 3 {
                    Text("Each wheel needs its own key.").foregroundStyle(.red).font(.caption)
                }
            }
            Section("Output") {
                Picker("Save new files", selection: $outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Reveal in Finder when done", isOn: $revealAfterFinish)
                Toggle("Play a sound when done", isOn: $playSound)
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Image(systemName: accessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibility ? .green : .orange)
                    Text(accessibility ? "Accessibility access granted" : "Accessibility access needed to see modifier keys")
                    Spacer()
                    if !accessibility {
                        Button("Open System Settings") { AccessibilityAccess.openSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func keyPicker(_ title: String, _ binding: Binding<String>) -> some View {
        Picker(title, selection: binding) {
            ForEach(ModifierKey.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }

    private var dependencies: some View {
        Form {
            Section {
                Text("Orbit converts images, PDFs, documents, subtitles and archives on its own. These optional tools unlock the rest. Everything runs locally; nothing is uploaded.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Optional helpers") {
                ForEach(Backend.allCases.filter { $0 != .native }, id: \.self) { backend in
                    let path = Backends.path(for: backend)
                    HStack {
                        Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(path != nil ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(backend.displayName).bold()
                            Text(path ?? "Not installed · " + purpose(backend)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if path == nil, let cmd = backend.brewCommand {
                            Button("Copy install command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            }
                        }
                    }
                }
                Button("Check again") { Backends.refresh(); backendRefresh += 1 }
            }
            .id(backendRefresh)
        }
        .formStyle(.grouped)
    }

    private func purpose(_ b: Backend) -> String {
        switch b {
        case .ffmpeg: return "video, audio, GIF, WebP, AVIF, ASS subtitles"
        case .pandoc: return "Markdown, EPUB, LaTeX"
        case .soffice: return "Word, PowerPoint, Excel, OpenDocument"
        case .sevenZip: return "7z archives"
        case .cwebp: return "WebP images (ffmpeg builds often lack the encoder)"
        case .native: return ""
        }
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid.circle").font(.system(size: 56)).foregroundStyle(.orange)
            Text("Orbit").font(.title).bold()
            Text("Drag a file. Hold a key. Drop it on the wheel.").foregroundStyle(.secondary)
            Divider().padding(.horizontal, 60)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Conversion paths").foregroundStyle(.secondary); Text("\(Catalog.conversionPathCount)") }
                GridRow { Text("File tools").foregroundStyle(.secondary); Text("\(Catalog.tools.count)") }
                GridRow { Text("File actions").foregroundStyle(.secondary); Text("\(Catalog.actions.count)") }
            }
            Text("Files never leave your Mac.").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
        .padding()
    }
}

enum AccessibilityAccess {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
