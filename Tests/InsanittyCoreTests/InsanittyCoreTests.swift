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

/// Decodes a payload captured live from the Go remote-engine helper over QUIC, proving
/// insanitty's Swift protocol layer interoperates with the real server (see
/// scripts/e2e-remote-engine.sh, which produced Fixtures/remote-grid-payload.jsonl).
final class RemoteGridProtocolTests: XCTestCase {
    private func fixtureLines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/remote-grid-payload.jsonl")
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n").map(String.init)
    }

    func testDecodesRealHelperPayload() throws {
        let lines = try fixtureLines()
        XCTAssertEqual(lines.count, 2, "fixture should be a workspaceSnapshot + a paneKeyframe")

        guard case let .workspaceSnapshot(snap) = try RemoteGridProtocol.decode(line: lines[0]) else {
            return XCTFail("first message should be a workspaceSnapshot")
        }
        XCTAssertEqual(snap.workspaceID, "insanitty-fixture")
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.panes.first?.frame.columns, 80)
        XCTAssertEqual(snap.panes.first?.frame.rows, 24)

        guard case let .paneKeyframe(kf) = try RemoteGridProtocol.decode(line: lines[1]) else {
            return XCTFail("second message should be a paneKeyframe")
        }
        XCTAssertEqual(kf.paneID, 0)
        XCTAssertEqual(kf.gridSize.columns, 80)
        XCTAssertEqual(kf.gridSize.rows, 24)
        XCTAssertEqual(kf.rows.count, 24, "keyframe should carry all 24 rows")
        // Compact `text` rows normalize to one width-1 cell per column.
        XCTAssertEqual(kf.rows.first?.cells.count, 80)
    }

    func testColorAndRowEncodings() throws {
        // Full-cell row with an indexed color + bold, and the Codable enum/color shapes.
        let json = """
        {"index":0,"rowVersion":1,"cells":[{"text":"X","width":1,"style":{"foreground":{"indexed":{"_0":4}},"background":{"default":{}},"underlineColor":{"default":{}},"bold":true,"faint":false,"italic":false,"blink":false,"inverse":false,"invisible":false,"strikethrough":false,"underline":"single"}}]}
        """
        let row = try JSONDecoder().decode(GridRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.cells.count, 1)
        XCTAssertEqual(row.cells[0].text, "X")
        XCTAssertEqual(row.cells[0].style.foreground, .indexed(4))
        XCTAssertTrue(row.cells[0].style.bold)
        XCTAssertEqual(row.cells[0].style.underline, .single)
    }
}

final class LinearURLTests: XCTestCase {
    func testParsesIssueURL() {
        XCTAssertEqual(LinearURL.parse("https://linear.app/acme/issue/ABC-123/some-title"),
                       .issue(identifier: "ABC-123"))
    }
    func testParsesProjectURL() {
        XCTAssertEqual(LinearURL.parse("https://linear.app/acme/project/q4-roadmap?tab=overview"),
                       .project(id: "q4-roadmap"))
    }
    func testIgnoresNonLinear() {
        XCTAssertNil(LinearURL.parse("https://github.com/blaine/fantastty/pull/18"))
        XCTAssertNil(LinearURL.parse("not a url"))
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

final class AppLayoutTests: XCTestCase {
    func testRoundTrip() throws {
        let layout = AppLayout(workspaces: [
            WorkspaceLayout(index: 0, name: "deep-mesa"),
            WorkspaceLayout(index: 1, name: "golden-peak", browserURLs: ["https://example.com"]),
            WorkspaceLayout(index: 5, name: "warm-maple", browserURLs: ["https://a.test", "https://b.test"]),
        ], selected: 1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("insanitty-layout-test-\(getpid())-\(layout.workspaces.count).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try LayoutStore.save(layout, to: url)
        XCTAssertEqual(LayoutStore.load(from: url), layout)
    }

    func testDefaultURLPrefersXDGStateHome() {
        let url = LayoutStore.defaultURL(environment: ["XDG_STATE_HOME": "/tmp/xdg-state"], home: "/home/x")
        XCTAssertEqual(url.path, "/tmp/xdg-state/insanitty/layout.json")
    }

    func testDefaultURLFallsBackToHome() {
        let url = LayoutStore.defaultURL(environment: [:], home: "/home/x")
        XCTAssertEqual(url.path, "/home/x/.local/state/insanitty/layout.json")
    }

    func testEmptyXDGStateHomeFallsBack() {
        let url = LayoutStore.defaultURL(environment: ["XDG_STATE_HOME": ""], home: "/home/x")
        XCTAssertEqual(url.path, "/home/x/.local/state/insanitty/layout.json")
    }

    func testLoadMissingFileReturnsNil() {
        XCTAssertNil(LayoutStore.load(from: URL(fileURLWithPath: "/nonexistent/insanitty/layout.json")))
    }
}
