import XCTest
@testable import Zurafa

final class ShellQuoteTests: XCTestCase {
    func testQuotesPathsButLeavesHomeForTheShell() {
        XCTAssertEqual(Workspace.shellQuotedPath("/Users/me/My Code"), "'/Users/me/My Code'")
        XCTAssertEqual(Workspace.shellQuotedPath("/tmp/it's"), #"'/tmp/it'\''s'"#)
        XCTAssertEqual(Workspace.shellQuotedPath("~"), "~")
        XCTAssertEqual(Workspace.shellQuotedPath("~/"), "~/")
        XCTAssertEqual(Workspace.shellQuotedPath("~/a b/$x"), "~/'a b/$x'")
        XCTAssertEqual(Workspace.shellQuotedPath("~bob"), "'~bob'")
        XCTAssertEqual(Workspace.shellQuotedPath("~/Projects/Zurafa"), "~/Projects/Zurafa")
        XCTAssertEqual(Workspace.shellQuotedPath("/opt/my-app_1.2"), "/opt/my-app_1.2")
    }
}
