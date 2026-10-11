import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = appIcon
        NSApp.activate(ignoringOtherApps: true)
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
                CommandMenu("Workspace") {
                    ForEach(Command.all) { c in
                        Button(c.title) { c.run(ws) }.keyboardShortcut(c.key, modifiers: c.mods)
                    }
                }
            }
    }
}
