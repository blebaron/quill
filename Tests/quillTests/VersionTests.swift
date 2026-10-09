import Foundation
import XCTest
@testable import quill

final class VersionTests: XCTestCase {
    func testCommandVersionMatchesReleaseVersion() {
        XCTAssertFalse(Quill.releaseVersion.isEmpty)
        XCTAssertEqual(Quill.configuration.version, Quill.releaseVersion)
        XCTAssertNotNil(Quill.releaseVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }

    func testInfoPlistSourceMatchesReleaseVersion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/quill/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, Quill.releaseVersion)
        let build = try XCTUnwrap(plist["CFBundleVersion"] as? String)
        XCTAssertGreaterThan(try XCTUnwrap(Int(build)), 0)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.digimata.quill")
    }
}
