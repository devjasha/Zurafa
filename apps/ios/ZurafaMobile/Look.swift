import SwiftUI

extension MacAppearance {
    /// nil follows the phone, as "system" on the Mac follows the Mac.
    var colorScheme: ColorScheme? { mode == "light" ? .light : mode == "dark" ? .dark : nil }
    func colors(_ scheme: ColorScheme) -> Colors { scheme == .dark ? dark : light }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension BlockSnapshot {
    /// The same detection the Mac's tab tiles use.
    func program(remote: RemoteHost?) -> Program {
        Program.detect(foreground?.name, executable: foreground?.executable, argv: foreground?.argv,
                       remote: remote != nil, remoteShell: remote?.shellProgram ?? .ssh)
    }
}

/// Paints a screen in the Mac's theme: its background, text and accent. Without one (an older Mac app) the system look stays.
struct MacLook: ViewModifier {
    @ObservedObject private var mac = MacClient.shared
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if let look = mac.appearance?.colors(scheme) {
            content
                .scrollContentBackground(.hidden)
                .background(Color(hex: look.background).ignoresSafeArea())
                .foregroundStyle(Color(hex: look.foreground))
                .tint(Color(hex: look.accent))
        } else {
            content
        }
    }
}
