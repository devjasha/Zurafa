import Foundation

struct SSHHostAddress: Equatable {
    let hostname: String
    let user: String?
    let port: Int

    var label: String {
        let parts = hostname.split(separator: ".")
        if parts.count > 1, !parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return String(parts[0])
        }
        return hostname
    }

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AddressError.empty }
        let destination: String
        if text.contains("://") {
            guard let url = URLComponents(string: text), url.scheme?.lowercased() == "ssh",
                  let host = url.host, !host.isEmpty,
                  url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/" else { throw AddressError.useSSH }
            destination = (url.user.map { "\($0)@" } ?? "") + host
            port = url.port ?? 22
        } else {
            guard !text.contains("/"), !text.contains("?") else { throw AddressError.useSSH }
            let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            destination = String(pieces[0])
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]) else { throw AddressError.invalidPort }
                port = parsed
            } else { port = 22 }
        }
        let parts = destination.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw AddressError.invalidHost }
        let host = String(parts.last ?? "")
        let parsedUser = parts.count == 2 ? String(parts[0]) : nil
        guard (1...65535).contains(port) else { throw AddressError.invalidPort }
        guard Self.valid(host, max: 255), !host.contains("@"), !host.contains("/"),
              !host.contains(":"), !host.starts(with: "-") else { throw AddressError.invalidHost }
        if let parsedUser {
            guard Self.valid(parsedUser, max: 64), !parsedUser.contains("@"),
                  !parsedUser.contains("/"), !parsedUser.starts(with: "-") else { throw AddressError.invalidUser }
        }
        hostname = host
        user = parsedUser
    }

    private static func valid(_ text: String, max: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= max && !text.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
        })
    }

    enum AddressError: LocalizedError {
        case empty, useSSH, invalidHost, invalidUser, invalidPort
        var errorDescription: String? {
            switch self {
            case .empty: "Type an SSH host address."
            case .useSSH: "Use ssh://user@host or a host name; HTTPS is not an SSH address."
            case .invalidHost: "Enter a valid SSH host name."
            case .invalidUser: "Enter a valid SSH user name."
            case .invalidPort: "SSH port must be between 1 and 65535."
            }
        }
    }
}
