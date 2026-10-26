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
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
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
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { ws.openConfig() }.keyboardShortcut(",")
                }
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { delegate.checkForUpdates() }
                }
                CommandMenu("Workspace") {
                    ForEach(Command.all) { c in
                        Button(c.title) { c.run(ws) }.keyboardShortcut(c.key, modifiers: c.mods)
                    }
                }
            }
    }
}
