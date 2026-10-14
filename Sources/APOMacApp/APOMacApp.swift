import SwiftUI

@main
struct APOMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var launchAtLogin = LaunchAtLogin()
    @State private var isImporterPresented = false

    var body: some Scene {
        Window("APOMac", id: AppDelegate.mainWindowID) {
            ContentView(model: model, isImporterPresented: $isImporterPresented)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Profile") { model.createProfile() }
                    .keyboardShortcut("n")
                Button("Import…") { isImporterPresented = true }
                    .keyboardShortcut("o")
            }
            CommandMenu("Equalizer") {
                Toggle("Processing", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Toggle("Bypass", isOn: $model.isBypassed)
                    .keyboardShortcut("b")
                    .disabled(model.selectedProfile == nil)
                Divider()
                Menu("Add Filter") {
                    ForEach(VisualFilterKind.bandKinds) { kind in
                        Button(kind.displayName) { model.addFilter(kind) }
                    }
                }
                .disabled(!model.visualEditorAvailable || model.selectedProfile == nil)
            }
        }

        Settings {
            SettingsView(model: model, launchAtLogin: launchAtLogin)
        }

        MenuBarExtra("APOMac", systemImage: model.isEnabled && !model.isBypassed ? "slider.vertical.3" : "slider.horizontal.below.square.filled.and.square") {
            MenuBarContent(model: model)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Processing", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
        Toggle("Bypass", isOn: $model.isBypassed)
            .disabled(model.selectedProfile == nil)
        Divider()
        OutputDevicePicker(model: model)
            .pickerStyle(.menu)
        Divider()
        if !model.profiles.isEmpty {
            Picker("Profile", selection: Binding(get: { model.selectedProfileID }, set: { model.selectProfile($0) })) {
                ForEach(model.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.inline)
            Divider()
        }
        Button("Open APOMac…") {
            AppDelegate.showInDock()
            openWindow(id: AppDelegate.mainWindowID)
            AppDelegate.bringMainWindowToFront()
        }
        OpenSettingsButton()
            .keyboardShortcut(",")
        Divider()
        Button("Quit APOMac") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLogin

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })) {
                    Text("Open at login")
                    Text("APOMac starts in the menu bar when you log in and resumes processing with your last profile.")
                }
                .disabled(!launchAtLogin.isAvailable)
                if !launchAtLogin.isAvailable {
                    Text("Available when running the installed APOMac.app (not with `swift run`).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if launchAtLogin.requiresApproval {
                    LabeledContent("Needs approval in System Settings") {
                        Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })) {
                    Text("Process system audio")
                    Text("Turn off to let other apps play unprocessed audio. Closing the window keeps APOMac running in the menu bar.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}

/// Opens the Settings window and brings it to the front, also when APOMac
/// is running from the menu bar only.
struct OpenSettingsButton: View {
    var title = "Settings…"
    var systemImage: String?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            AppDelegate.showInDock()
            openSettings()
            NSApp.activate()
        } label: {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowID = "main"

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `swift run` starts an unbundled executable, which macOS treats as
        // background-only: its window stays behind other apps and can never
        // be activated. Make it a regular app (Dock icon, activatable window).
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        // The Dock icon is shown only while a window is open; with every
        // window closed APOMac lives in the menu bar.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Self.updateDockPresence() } }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.updateDockPresence() }
        }

        if LaunchAtLogin.launchedAsLoginItem {
            // Started at login: process audio quietly from the menu bar.
            for window in NSApp.windows where Self.isUserWindow(window) {
                window.close()
            }
            NSApp.setActivationPolicy(.accessory)
        } else {
            Self.bringMainWindowToFront()
        }
    }

    /// Keep processing in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopening the app (Finder, Spotlight, Launchpad) shows the window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.showInDock()
        return true
    }

    @MainActor
    static func showInDock() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @MainActor
    static func bringMainWindowToFront() {
        showInDock()
        // openWindow creates the window asynchronously; activate on the next turn.
        DispatchQueue.main.async {
            NSApp.activate()
            let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(mainWindowID) == true && $0.canBecomeMain }
                ?? NSApp.windows.first { $0.canBecomeMain }
            window?.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private static func updateDockPresence() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && isUserWindow($0) }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// Regular titled windows (main window, Settings, open/save panels),
    /// not the menu bar extra's menu.
    @MainActor
    private static func isUserWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.level == .normal
    }
}
