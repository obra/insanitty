// In-process, SPKI-pinned QUIC fetch of a remote workspace. Connects to the remote-engine helper,
// collects the workspaceSnapshot + a paneKeyframe per pane, and returns them — so the GUI can map
// the remote workspace's panes onto GtkPaned splits and render each. Blocking: run on a background
// thread. This replaces the quic-client subprocess for the GUI's remote workspace.
import CGhostty
import CMsQuic
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// One msquic handle + registration, opened once and reused across all fetches. Closing a
// registration deadlocks on its worker threads, so we keep exactly one for the app's lifetime —
// this is what lets the remote workspace poll continuously without leaking a registration per fetch.
nonisolated(unsafe) var gQuicApi: UnsafePointer<QUIC_API_TABLE>?
nonisolated(unsafe) var gQuicReg: OpaquePointer?
func sharedQuic() -> (UnsafePointer<QUIC_API_TABLE>, OpaquePointer)? {
    if let a = gQuicApi, let r = gQuicReg { return (a, r) }
    var apiRaw: UnsafeRawPointer?
    guard MsQuicOpenVersion(2, &apiRaw) == 0, let raw = apiRaw else { return nil }
    let a = raw.assumingMemoryBound(to: QUIC_API_TABLE.self)
    var reg: OpaquePointer?
    _ = a.pointee.RegistrationOpen(nil, &reg)
    guard let r = reg else { return nil }
    gQuicApi = a; gQuicReg = r
    return (a, r)
}

final class RemoteQuicFetcher {
    var api: UnsafePointer<QUIC_API_TABLE>!
    private var received = Data()
    private(set) var snapshot: WorkspaceSnapshot?
    private(set) var keyframes: [Int: PaneKeyframe] = [:]
    private var expectedPanes: Set<Int>?
    let expectedPin: String
    var attach: [UInt8]
    var attachBuf = QUIC_BUFFER()
    // Optional input to forward to the remote pane after attach (sendKeys + requestKeyframe).
    var workspaceID = ""
    var inputBytes: [UInt8] = []
    var inputPane = 0
    private var sendKeysBytes: [UInt8] = []; private var sendKeysBuf = QUIC_BUFFER()
    private var reqKfBytes: [UInt8] = [];    private var reqKfBuf = QUIC_BUFFER()
    var stream: OpaquePointer?               // the attach stream, kept to request a keyframe later (set from remoteConnCb)
    var heldConn: OpaquePointer?             // kept open in hold mode so repoll() reuses one connection
    var heldConfig: OpaquePointer?
    let sem = DispatchSemaphore(value: 0)
    let lock = NSLock()

    init(bootstrap: RemoteBootstrapLine) {
        expectedPin = bootstrap.certSHA256
        attach = Array("{\"session\":\"\(bootstrap.session)\",\"key\":\"\(bootstrap.key)\"}\n".utf8)
    }

    /// For tests: a fetcher with no live connection, populated from a jsonl fixture of messages.
    init() { expectedPin = ""; attach = [] }
    func loadFixture(_ data: Data) {
        Array(data).withUnsafeBufferPointer { bp in if let base = bp.baseAddress { ingest(base, bp.count) } }
    }

    /// Connect, collect the snapshot + pane keyframes (blocking, with an 8s timeout). Returns true
    /// if anything was received. With `hold`, the connection is kept open afterwards so `repoll()`
    /// can reuse it — keeping the helper's tmux client attached so external output keeps streaming.
    func fetch(host: String, port: UInt16, hold: Bool = false) -> Bool {
        guard let (sharedApi, reg) = sharedQuic() else { return false }
        api = sharedApi
        var config: OpaquePointer?
        let alpn = Array("fantastty-remote-engine-v1".utf8)
        alpn.withUnsafeBufferPointer { ap in
            var alpnBuf = QUIC_BUFFER(Length: UInt32(ap.count), Buffer: UnsafeMutablePointer(mutating: ap.baseAddress))
            _ = api.pointee.ConfigurationOpen(reg, &alpnBuf, 1, nil, 0, nil, &config)
        }
        var cred = QUIC_CREDENTIAL_CONFIG()
        cred.Type = QUIC_CREDENTIAL_TYPE_NONE
        cred.Flags = QUIC_CREDENTIAL_FLAGS(rawValue:
            QUIC_CREDENTIAL_FLAG_CLIENT.rawValue | QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION.rawValue
            | QUIC_CREDENTIAL_FLAG_INDICATE_CERTIFICATE_RECEIVED.rawValue
            | QUIC_CREDENTIAL_FLAG_USE_PORTABLE_CERTIFICATES.rawValue)
        _ = api.pointee.ConfigurationLoadCredential(config, &cred)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var conn: OpaquePointer?
        _ = api.pointee.ConnectionOpen(reg, remoteConnCb, ctx, &conn)
        _ = host.withCString { hp in api.pointee.ConnectionStart(conn, config, UInt16(0), hp, port) }
        _ = sem.wait(timeout: .now() + 8)
        // The keyframe sent on attach can be stale, so always request a FRESH keyframe for the
        // active pane before reading the result — this is what makes the workspace auto-update to
        // the current remote state on each poll. With queued input, send the keys first and give
        // the shell time to process them so the echoed output is in the captured grid.
        if workspaceID.isEmpty { workspaceID = "insanitty-remote-gui" }
        if let active = snapshot?.panes.first(where: { $0.isActive })?.paneID ?? keyframes.keys.sorted().first {
            inputPane = active
        }
        if !inputBytes.isEmpty {
            usleep(1_500_000)
            requestFreshKeyframe()
            usleep(1_500_000)
        } else {
            requestFreshKeyframe()
            usleep(1_500_000)
        }
        if hold {
            heldConn = conn; heldConfig = config   // keep the connection open for repoll()
        } else {
            // ConnectionClose blocks until this connection's callbacks have drained, so no callback
            // fires on this fetcher after it's released. (The shared registration is never closed —
            // closing a registration deadlocks on its worker threads.)
            if let conn = conn { api.pointee.ConnectionClose(conn) }
            if let config = config { api.pointee.ConfigurationClose(config) }
        }
        return snapshot != nil || !keyframes.isEmpty
    }

    /// Reuse the held-open connection: forward any queued input, then request a fresh keyframe for
    /// the active pane and let it round-trip. Because the connection stays attached, the helper keeps
    /// observing the tmux session, so this reflects external output too. Blocking; run off-main.
    func repoll() {
        guard heldConn != nil else { return }
        if let active = snapshot?.panes.first(where: { $0.isActive })?.paneID ?? keyframes.keys.sorted().first {
            inputPane = active
        }
        if !inputBytes.isEmpty {
            sendInputIfNeeded(stream)
            usleep(1_500_000)
        }
        requestFreshKeyframe()
        usleep(1_500_000)
    }

    /// Close the held-open connection (app shutdown).
    func closeHeld() {
        if let conn = heldConn { api.pointee.ConnectionClose(conn); heldConn = nil }
        if let config = heldConfig { api.pointee.ConfigurationClose(config); heldConfig = nil }
    }

    /// Validate the SPKI cert pin (self-signed cert; msquic's own validation is off).
    func handleCert(_ ev: UnsafeMutablePointer<QUIC_CONNECTION_EVENT>) -> UInt32 {
        guard let buf = ins_cert_buffer(ev), let der = buf.pointee.Buffer else { return 1 }
        var out = [CChar](repeating: 0, count: 65)
        let got = ins_spki_sha256_hex(der, Int(buf.pointee.Length), &out) == 0 ? String(cString: out) : ""
        return got.lowercased() == expectedPin.lowercased() ? 0 : 1
    }

    /// After attach, forward any queued keystrokes to the active pane. The request buffer is an
    /// instance var so it outlives the async StreamSend.
    func sendInputIfNeeded(_ stream: OpaquePointer?) {
        guard !inputBytes.isEmpty else { return }
        FileHandle.standardError.write(Data("insanitty: forwarding \(inputBytes.count) input byte(s) to pane \(inputPane)\n".utf8))
        let b64 = Data(inputBytes).base64EncodedString()
        sendKeysBytes = Array("{\"type\":\"sendKeys\",\"workspaceID\":\"\(workspaceID)\",\"paneID\":\(inputPane),\"data\":\"\(b64)\"}\n".utf8)
        sendKeysBytes.withUnsafeMutableBufferPointer { bp in
            sendKeysBuf.Length = UInt32(bp.count); sendKeysBuf.Buffer = bp.baseAddress
            _ = api.pointee.StreamSend(stream, &sendKeysBuf, 1, QUIC_SEND_FLAG_NONE, nil)
        }
    }

    /// Ask the remote for a full keyframe — called after a delay so the shell has processed the
    /// forwarded keystrokes and the echoed output is in the captured grid.
    func requestFreshKeyframe() {
        guard let stream = stream else { return }
        reqKfBytes = Array("{\"type\":\"requestKeyframe\",\"workspaceID\":\"\(workspaceID)\",\"paneID\":\(inputPane)}\n".utf8)
        reqKfBytes.withUnsafeMutableBufferPointer { bp in
            reqKfBuf.Length = UInt32(bp.count); reqKfBuf.Buffer = bp.baseAddress
            _ = api.pointee.StreamSend(stream, &reqKfBuf, 1, QUIC_SEND_FLAG_NONE, nil)
        }
    }

    func ingest(_ ptr: UnsafePointer<UInt8>, _ len: Int) {
        lock.lock(); defer { lock.unlock() }
        received.append(ptr, count: len)
        let text = String(decoding: received, as: UTF8.self)
        guard let lastNL = text.lastIndex(of: "\n") else { return }
        for line in text[..<lastNL].split(separator: "\n").map(String.init) {
            guard let msg = try? RemoteGridProtocol.decode(line: line) else { continue }
            switch msg {
            case .workspaceSnapshot(let s): snapshot = s; expectedPanes = Set(s.panes.map { $0.paneID })
            case .paneKeyframe(let kf): keyframes[kf.paneID] = kf
            default: break
            }
        }
        if let exp = expectedPanes, !exp.isEmpty, exp.isSubset(of: Set(keyframes.keys)) { sem.signal() }
    }
}

let remoteConnCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_CONNECTION_EVENT>?) -> UInt32 = { conn, ctx, ev in
    guard let ev = ev, let ctx = ctx else { return 0 }
    let f = Unmanaged<RemoteQuicFetcher>.fromOpaque(ctx).takeUnretainedValue()
    switch ev.pointee.Type {
    case QUIC_CONNECTION_EVENT_PEER_CERTIFICATE_RECEIVED:
        return f.handleCert(ev)
    case QUIC_CONNECTION_EVENT_CONNECTED:
        var stream: OpaquePointer?
        _ = f.api.pointee.StreamOpen(conn, QUIC_STREAM_OPEN_FLAG_NONE, remoteStreamCb, ctx, &stream)
        _ = f.api.pointee.StreamStart(stream, QUIC_STREAM_START_FLAG_IMMEDIATE)
        f.stream = stream
        f.attach.withUnsafeMutableBufferPointer { bp in
            f.attachBuf.Length = UInt32(bp.count); f.attachBuf.Buffer = bp.baseAddress
            _ = f.api.pointee.StreamSend(stream, &f.attachBuf, 1, QUIC_SEND_FLAG_NONE, nil)
        }
        f.sendInputIfNeeded(stream)
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
        f.sem.signal()
    default: break
    }
    return 0
}

let remoteStreamCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_STREAM_EVENT>?) -> UInt32 = { _, ctx, ev in
    guard let ev = ev, ev.pointee.Type == QUIC_STREAM_EVENT_RECEIVE, let ctx = ctx else { return 0 }
    let f = Unmanaged<RemoteQuicFetcher>.fromOpaque(ctx).takeUnretainedValue()
    let n = Int(ins_recv_count(ev))
    if let bufs = ins_recv_buffers(ev) {
        for i in 0..<n { let b = bufs[i]; if let p = b.Buffer { f.ingest(p, Int(b.Length)) } }
    }
    return 0
}
