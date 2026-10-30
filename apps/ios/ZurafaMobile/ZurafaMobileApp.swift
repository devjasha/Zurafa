import SwiftUI

@main
struct ZurafaMobileApp: App {
    @UIApplicationDelegateAdaptor(Notifications.self) private var notifications
    @Environment(\.scenePhase) private var phase
    @AppStorage("macAddress") private var address = ""

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { if !address.isEmpty { MacClient.shared.connect(to: address) } }
                .onChange(of: phase) { _, phase in if phase == .active { MacClient.shared.resume() } }
        }
    }
}

struct RootView: View {
    @AppStorage("macAddress") private var address = ""
    @ObservedObject private var mac = MacClient.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if address.isEmpty { ConnectView() } else { SessionsView() }
        }
        // Light, dark or following the phone, as set on the Mac.
        .preferredColorScheme(mac.appearance?.colorScheme)
        .task(id: mac.state) { if mac.state == .connected { Notifications.enable() } }
        .task(id: mac.appearance?.colors(scheme)) { Terminals.shared.colors = mac.appearance?.colors(scheme) }
    }
}

/// First run: name the Mac. Tailscale decides who gets in, so there is nothing to pair.
struct ConnectView: View {
    @ObservedObject private var mac = MacClient.shared
    @AppStorage("macAddress") private var saved = ""
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("my-mac.tail1234.ts.net", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(connect)
                } header: {
                    Text("Your Mac's Tailscale name")
                } footer: {
                    Text("On the Mac, open Zurafa → Settings → Server and turn on \"Allow connections from your devices\". Sign this iPhone in to the same Tailscale account.")
                }
                Section {
                    Button("Connect", action: connect).disabled(address.isEmpty || mac.state == .connecting)
                    if mac.state == .connecting { ProgressView() }
                    if case .failed(let reason) = mac.state { Text(reason).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Zurafa")
        }
        .onChange(of: mac.state) { _, state in if state == .connected { saved = address } }
    }

    private func connect() { mac.connect(to: address) }
}
