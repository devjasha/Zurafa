import XCTest
@testable import Zurafa

final class SSHHostAddressTests: XCTestCase {
    func testAcceptsSystemSSHAddressesAndTailnetNames() throws {
        let tailnet = try SSHHostAddress("ssh://alice@machine.tailnet.ts.net:2222")
        XCTAssertEqual(tailnet.hostname, "machine.tailnet.ts.net")
        XCTAssertEqual(tailnet.user, "alice")
        XCTAssertEqual(tailnet.port, 2222)
        XCTAssertEqual(tailnet.label, "machine")
        let alias = try SSHHostAddress("workbox")
        XCTAssertEqual(alias.hostname, "workbox")
        XCTAssertNil(alias.user)
        XCTAssertEqual(alias.port, 22)
        XCTAssertEqual(try SSHHostAddress("bob@server.example:2200").port, 2200)
    }

    func testRejectsWebAndUnsafeSSHAddresses() {
        for input in ["https://machine.tailnet.ts.net", "ssh://host/path", "-oProxyCommand=bad",
                      "user name@host", "host:0", "host:99999", "user@@host", "host/path"] {
            XCTAssertThrowsError(try SSHHostAddress(input), input)
        }
    }
}
