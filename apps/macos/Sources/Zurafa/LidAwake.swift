import Foundation
import IOKit.ps

/// "Stay reachable with the lid closed". macOS sleeps on lid close unless `pmset disablesleep` is on,
/// which needs root: one admin prompt installs a sudoers rule for exactly that command, so Zurafa
/// can switch it with the power source. On battery, and when Zurafa quits, the Mac sleeps as usual.
@MainActor final class LidAwake {
    static let shared = LidAwake()
    static let key = "stayAwakeWithLidClosed"
    private static let rule = "/etc/sudoers.d/zurafa-disablesleep"
    private var applied: Bool?
    private var source: CFRunLoopSource?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    /// Follows power-source changes from launch on; also undoes a setting left on by a crash.
    func start() {
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { LidAwake.shared.apply() }
        }, nil).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
        apply(force: true)
    }

    func setEnabled(_ on: Bool) throws {
        if on, !FileManager.default.fileExists(atPath: Self.rule) { try installRule() }
        UserDefaults.standard.set(on, forKey: Self.key)
        apply()
    }

    /// Back to normal sleep, for quitting.
    func stop() { set(false) }

    private func apply(force: Bool = false) {
        let awake = enabled && Self.onPower
        let wasAwake = applied == true
        if force || awake != applied { set(awake) }
        // Unplugged (or switched off) with the lid already closed: nothing else would put the Mac to sleep now.
        // Only after keeping it awake ourselves, never e.g. a lid-closed Mac on an external display.
        if wasAwake && !awake && Self.lidClosed { run("/usr/bin/pmset", ["sleepnow"]) }
    }

    private func set(_ awake: Bool) {
        // Only ever touch the setting once the rule exists, so a user who never opted in sees no sudo.
        guard FileManager.default.fileExists(atPath: Self.rule) else { return }
        if run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", awake ? "1" : "0"]) { applied = awake }
    }

    private static var onPower: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMACPowerKey
    }

    private static var lidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, nil, 0)?.takeRetainedValue() as? Bool ?? false
    }

    /// Lets this user, without a password, run only `pmset -a disablesleep 0|1` as root. Checked by visudo before it lands.
    private func installRule() throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw DaemonError("Unsupported user name \(user)") }
        let line = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zurafa-disablesleep")
        try (line + "\n").write(to: tmp, atomically: true, encoding: .utf8)
        let shell = "/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' \(Self.rule)"
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(shell)\" with administrator privileges")?.executeAndReturnError(&error)
        try? FileManager.default.removeItem(at: tmp)
        if let error { throw DaemonError(error[NSAppleScript.errorMessage] as? String ?? "Could not get permission to change sleep settings") }
    }

    @discardableResult private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
