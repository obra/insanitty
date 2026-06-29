import XCTest
import Foundation
@testable import InsanittyCore

final class WorkspaceNameTests: XCTestCase {
    func testVocabularySizes() {
        XCTAssertEqual(WorkspaceName.adjectives.count, 20)
        XCTAssertEqual(WorkspaceName.nouns.count, 20)
    }

    func testGeneratedNamesAreWellFormed() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let name = WorkspaceName.generate(using: &rng)
            XCTAssertTrue(WorkspaceName.isWellFormed(name), "not well-formed: \(name)")
            XCTAssertEqual(name.split(separator: "-").count, 2)
        }
    }

    func testKnownExampleIsWellFormed() {
        XCTAssertTrue(WorkspaceName.isWellFormed("bold-falcon"))
        XCTAssertFalse(WorkspaceName.isWellFormed("bold"))
        XCTAssertFalse(WorkspaceName.isWellFormed("nonsense-word"))
    }
}

final class RemoteBootstrapLineTests: XCTestCase {
    private let session = String(repeating: "a", count: 64)
    private let key = String(repeating: "b", count: 64)
    private let cert = String(repeating: "c", count: 64)

    func testParsesValidLine() throws {
        let line = "FANTASTTY_REMOTE port=7 session=\(session) key=\(key) "
            + "expires=2026-06-29T12:00:00Z helper_pid=4242 version=0.2.1 arch=linux-amd64 "
            + "quic_addr=10.0.0.5:51820 quic_cert_sha256=\(cert) quic_alpn=fantastty-remote-engine-v1"
        let r = try RemoteBootstrapLine.parse(line)
        XCTAssertEqual(r.host, "10.0.0.5")
        XCTAssertEqual(r.port, 51820)
        XCTAssertEqual(r.session, session)
        XCTAssertEqual(r.key, key)
        XCTAssertEqual(r.certSHA256, cert)
        XCTAssertEqual(r.alpn, "fantastty-remote-engine-v1")
        XCTAssertEqual(r.version, "0.2.1")
        XCTAssertEqual(r.arch, "linux-amd64")
        XCTAssertEqual(r.helperPID, 4242)
        XCTAssertNotNil(r.expires)
    }

    func testParsesBracketedIPv6() throws {
        let line = "FANTASTTY_REMOTE session=\(session) key=\(key) "
            + "quic_addr=[fe80::1]:443 quic_cert_sha256=\(cert)"
        let r = try RemoteBootstrapLine.parse(line)
        XCTAssertEqual(r.host, "fe80::1")
        XCTAssertEqual(r.port, 443)
    }

    func testRejectsMissingPrefix() {
        XCTAssertThrowsError(try RemoteBootstrapLine.parse("session=\(session)")) { err in
            XCTAssertEqual(err as? RemoteBootstrapLine.ParseError, .missingPrefix)
        }
    }

    func testRejectsShortHexKey() {
        let line = "FANTASTTY_REMOTE session=\(session) key=deadbeef "
            + "quic_addr=h:1 quic_cert_sha256=\(cert)"
        XCTAssertThrowsError(try RemoteBootstrapLine.parse(line)) { err in
            XCTAssertEqual(err as? RemoteBootstrapLine.ParseError, .malformedHex("key"))
        }
    }

    func testRejectsMissingAddr() {
        let line = "FANTASTTY_REMOTE session=\(session) key=\(key) quic_cert_sha256=\(cert)"
        XCTAssertThrowsError(try RemoteBootstrapLine.parse(line)) { err in
            XCTAssertEqual(err as? RemoteBootstrapLine.ParseError, .missingField("quic_addr"))
        }
    }
}

final class SplitGeometryTests: XCTestCase {
    func testInteractiveClamp() {
        XCTAssertEqual(SplitGeometry.clampInteractive(0.0), 0.1, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampInteractive(1.0), 0.9, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampInteractive(0.5), 0.5, accuracy: 1e-9)
    }

    func testTmuxClamp() {
        XCTAssertEqual(SplitGeometry.clampTmux(0.0), 0.05, accuracy: 1e-9)
        XCTAssertEqual(SplitGeometry.clampTmux(1.0), 0.95, accuracy: 1e-9)
    }

    func testAllocateNeverCollapsesBelowMin() {
        let total = 200.0
        for ratio in stride(from: -0.5, through: 1.5, by: 0.1) {
            let (a, b) = SplitGeometry.allocate(total: total, ratio: ratio)
            XCTAssertGreaterThanOrEqual(a, SplitGeometry.minPaneSize - 1e-9)
            XCTAssertGreaterThanOrEqual(b, SplitGeometry.minPaneSize - 1e-9)
            XCTAssertEqual(a + b, total, accuracy: 1e-9)
        }
    }
}
