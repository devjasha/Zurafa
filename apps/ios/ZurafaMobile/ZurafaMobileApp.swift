import SwiftUI
import VisionKit

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
    @State private var pairing: String?

    var body: some View {
        Group {
            if address.isEmpty { ConnectView() } else { SessionsView() }
        }
        .onOpenURL { url in
            guard let pair = Self.pairAddress(url), pair != address else { return }
            if address.isEmpty { use(pair) } else { pairing = pair }
        }
        .alert("Switch to \(pairing ?? "")?", isPresented: Binding(get: { pairing != nil }, set: { if !$0 { pairing = nil } })) {
            Button("Switch") { if let pairing { use(pairing) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zurafa disconnects from \(address) and connects to this Mac instead.")
        }
        // Light, dark or following the phone, as set on the Mac.
        .preferredColorScheme(mac.appearance?.colorScheme)
        .task(id: mac.state) { if mac.state == .connected { Notifications.enable() } }
        .task(id: mac.appearance?.colors(scheme)) { Terminals.shared.colors = mac.appearance?.colors(scheme) }
    }
}

extension RootView {
    /// The Mac named by a pairing QR code. Only Tailscale names, so a link from elsewhere cannot
    /// point the app at a server outside the tailnet.
    static func pairAddress(_ url: URL) -> String? {
        guard url.scheme == "zurafa", url.host == "connect",
              let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "address" })?.value?.lowercased(),
              address.hasSuffix(".ts.net"), !address.contains("/"), !address.contains("@")
        else { return nil }
        return address
    }

    private func use(_ pair: String) {
        address = pair
        MacClient.shared.connect(to: pair)
    }
}

/// First run: scan the Mac's Pair code or name the Mac. Tailscale decides who gets in.
struct ConnectView: View {
    @ObservedObject private var mac = MacClient.shared
    @AppStorage("macAddress") private var saved = ""
    @State private var address = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                if DataScannerViewController.isSupported {
                    Section {
                        Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                    } footer: {
                        Text("On the Mac, open Zurafa → Settings → Server, turn on \"Serve over Tailscale\" and click Pair.")
                    }
                }
                Section {
                    TextField("my-mac-zurafa.tail1234.ts.net", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(connect)
                } header: {
                    Text("Your Mac's Tailscale name")
                } footer: {
                    Text("Or type the Remote Address from Zurafa → Settings → Server on the Mac. Sign this iPhone in to the same Tailscale account.")
                }
                Section {
                    Button("Connect", action: connect).disabled(address.isEmpty || mac.state == .connecting)
                    if mac.state == .connecting { ProgressView() }
                    if case .failed(let reason) = mac.state { Text(reason).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Zurafa")
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    PairScanner { scanned in
                        scanning = false
                        address = scanned
                        connect()
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan Pair Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel", role: .cancel) { scanning = false } }
                }
            }
        }
        .onChange(of: mac.state) { _, state in if state == .connected { saved = address } }
    }

    private func connect() { mac.connect(to: address) }
}

/// The camera, looking for a Pair code (`zurafa://connect?address=…`); other QR codes are ignored.
struct PairScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        // Asks for the camera the first time; if refused, the view stays dark and Cancel still works.
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let url = code.payloadStringValue.flatMap(URL.init(string:)),
                      let address = RootView.pairAddress(url) else { continue }
                done = true
                scanner.stopScanning()
                found(address)
            }
        }
    }
}
