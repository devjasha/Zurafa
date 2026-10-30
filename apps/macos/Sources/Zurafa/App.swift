import Sparkle
import SwiftUI

/// An `ObservableObject`, so SwiftUI puts it in every view's environment.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, SPUUpdaterDelegate {
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    /// Version of a newer release Sparkle found; drives the update indicators.
    @Published private(set) var availableUpdate: String?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = appIcon
        NSApp.activate(ignoringOtherApps: true)
        CLIInstaller.offerInstallIfNeeded()
        // Silent probe: reports through the delegate without showing Sparkle's window.
        updaterController.updater.checkForUpdateInformation()
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdate = item.displayVersionString
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdate = nil
    }
    /// Sparkle stores this; objectWillChange refreshes the toggle bound to it.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updaterController.updater.automaticallyChecksForUpdates = newValue }
    }
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Like Rex, Zurafa stays in the menu bar after its last window closes; Quit is in that menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

@main struct ZurafaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var ws = Workspace()

    var body: some Scene {
        Window("Zurafa", id: "main") { RootView().environmentObject(ws) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1280, height: 800)
            .commands {
                // Free Cmd-W and Cmd-T from the stock Close and Show Fonts items.
                CommandGroup(replacing: .saveItem) {}
                CommandGroup(replacing: .textFormatting) {}
                CommandGroup(replacing: .appSettings) { SettingsMenuItem() }
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { delegate.checkForUpdates() }
                }
                CommandMenu("Workspace") {
                    ForEach(Command.all) { c in
                        Button(c.title) { c.run(ws) }.keyboardShortcut(c.key, modifiers: c.mods)
                    }
                }
            }
        // A Window, not a Settings scene: the Settings scene gives a split view a doubled title bar.
        Window("Settings", id: "settings") { SettingsView().environmentObject(ws).environmentObject(delegate) }
            .windowResizability(.contentSize)
        MenuBarExtra { ServerMenu().environmentObject(delegate) } label: { ServerMenuIcon() }
    }
}

/// Menu bar status of the local zurafa-daemon: a server while it answers, a warning when it does not.
private struct ServerMenuIcon: View {
    @ObservedObject private var daemon = DaemonClient.shared
    var body: some View {
        Image(systemName: daemon.down ? "exclamationmark.triangle" : daemon.stale ? "arrow.triangle.2.circlepath" : "server.rack")
            .help(daemon.down ? "Zurafa Server is not running" : daemon.stale ? "Restart Zurafa Server to finish the update" : "Zurafa Server is running")
    }
}

private struct ServerMenu: View {
    @ObservedObject private var daemon = DaemonClient.shared
    @EnvironmentObject var app: AppDelegate
    @AppStorage(ServerPane.listenKey) private var listen = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Menus drop a label's subtitle and icon, so the state goes in the title.
        Button("Zurafa Server: \(daemon.down ? "Not running" : "Running")") { openSettings(.server) }
        if !daemon.down && daemon.stale { Button("Restart Server to Finish Update…") { openSettings(.server) } }
        if !daemon.down && listen { Text("Open to your Tailscale devices") }
        if daemon.down { Button("Reconnect") { daemon.start() } }
        Divider()
        Text("Zurafa \(CLIInstaller.appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
        Divider()
        Button("Check for Updates…") { app.checkForUpdates() }
        Button("Settings…") { openSettings(nil) }.keyboardShortcut(",")
        Divider()
        Button("Quit Zurafa") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func openSettings(_ pane: SettingsPane?) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsView.paneKey) }
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Settings…") { openWindow(id: "settings") }.keyboardShortcut(",") }
}
