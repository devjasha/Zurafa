import AppKit
import Foundation

enum CLIInstaller {
    static let installPath = "/usr/local/bin/zurafa"
    private static let promptDeclinedVersionKey = "zurafaCLIPromptDeclinedVersion"

    @MainActor static func offerInstallIfNeeded() {
        guard offersInstall else { return }
        guard let sourcePath = bundledCLIPath(), needsInstall(sourcePath: sourcePath) else { return }
        guard UserDefaults.standard.string(forKey: promptDeclinedVersionKey) != appVersion else { return }

        let alert = NSAlert()
        alert.messageText = "Install the Zurafa command-line tool?"
        alert.informativeText = "This creates /usr/local/bin/zurafa so you can run `zurafa` from any terminal. macOS may ask for your password."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try install(sourcePath: sourcePath)
                UserDefaults.standard.removeObject(forKey: promptDeclinedVersionKey)
            } catch {
                showFailure(error)
            }
        } else {
            UserDefaults.standard.set(appVersion, forKey: promptDeclinedVersionKey)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var offersInstall: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ZURAFAOffersCLIInstall") as? Bool ?? true
    }

    static func bundledCLIPath() -> String? {
        Bundle.main.url(forResource: "zurafa", withExtension: nil)?.path
    }

    static func needsInstall(sourcePath: String, installPath: String = installPath) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: sourcePath) else { return false }
        guard FileManager.default.fileExists(atPath: installPath) else { return true }

        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: installPath) else {
            return false
        }

        return standardizedSymlinkDestination(destination, at: installPath) != standardizedPath(sourcePath)
    }

    static func install(sourcePath: String, installPath: String = installPath) throws {
        if canReplace(installPath: installPath) {
            do {
                try installWithoutPrivileges(sourcePath: sourcePath, installPath: installPath)
                return
            } catch {
                try installWithPrivileges(sourcePath: sourcePath, installPath: installPath)
            }
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func installWithoutPrivileges(sourcePath: String, installPath: String) throws {
        let directory = URL(fileURLWithPath: installPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installPath) {
            try FileManager.default.removeItem(atPath: installPath)
        }
        try FileManager.default.createSymbolicLink(atPath: installPath, withDestinationPath: sourcePath)
    }

    private static func installWithPrivileges(sourcePath: String, installPath: String) throws {
        let directory = URL(fileURLWithPath: installPath).deletingLastPathComponent().path
        let command = "/bin/mkdir -p \(shellQuoted(directory)) && /bin/rm -f \(shellQuoted(installPath)) && /bin/ln -s \(shellQuoted(sourcePath)) \(shellQuoted(installPath))"
        let script = "do shell script \(String(reflecting: command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NSError(domain: "Zurafa.CLIInstaller", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Could not install /usr/local/bin/zurafa."])
        }
    }

    private static func canReplace(installPath: String) -> Bool {
        !FileManager.default.fileExists(atPath: installPath) || (try? FileManager.default.destinationOfSymbolicLink(atPath: installPath)) != nil
    }

    private static func standardizedSymlinkDestination(_ destination: String, at linkPath: String) -> String {
        let path = destination.hasPrefix("/")
            ? destination
            : URL(fileURLWithPath: linkPath).deletingLastPathComponent().appendingPathComponent(destination).path
        return standardizedPath(path)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    @MainActor private static func showFailure(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Could not install the Zurafa CLI"
        alert.runModal()
    }
}
