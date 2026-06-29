// Native Swift QUIC client for insanitty's remote engine (binds msquic). Attaches to the
// remote-engine helper over QUIC, sends the {session,key} attach, reads the reliable stream,
// and decodes the structured grid with InsanittyCore.RemoteGridProtocol — the native transport
// that replaces the Go-probe subprocess bridge.
// Usage: quic-client <host> <port> <session-hex> <key-hex>
import CMsQuic
import Foundation

nonisolated(unsafe) var gApi: UnsafePointer<QUIC_API_TABLE>!
nonisolated(unsafe) var gAttach: [UInt8] = []
nonisolated(unsafe) var gAttachBuf = QUIC_BUFFER()
nonisolated(unsafe) var gReceived = Data()
nonisolated(unsafe) var gResult: String?
let gLock = NSLock()
let gSem = DispatchSemaphore(value: 0)

// Append received bytes and, once a complete paneKeyframe line is present, decode it here
// (under the lock) so the main thread never reads mid-mutation.
func ingest(_ ptr: UnsafePointer<UInt8>, _ len: Int) {
    gLock.lock(); defer { gLock.unlock() }
    gReceived.append(ptr, count: len)
    guard gResult == nil, gReceived.contains(0x0A) else { return }
    let text = String(decoding: gReceived, as: UTF8.self)
    // Only consider complete (newline-terminated) lines.
    let complete = text.hasSuffix("\n") ? text : text[..<text.lastIndex(of: "\n")!].description
    for line in complete.split(separator: "\n").map(String.init) {
        if let msg = try? RemoteGridProtocol.decode(line: line), case let .paneKeyframe(kf) = msg {
            gResult = "NATIVE-QUIC-OK: native Swift client got paneKeyframe over QUIC — grid=\(kf.gridSize.columns)x\(kf.gridSize.rows), rows=\(kf.rows.count)"
            gSem.signal()
            return
        }
    }
}

let streamCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_STREAM_EVENT>?) -> UInt32 = { _, _, ev in
    guard let ev = ev, ev.pointee.Type == QUIC_STREAM_EVENT_RECEIVE else { return 0 }
    let n = Int(ins_recv_count(ev))
    if let bufs = ins_recv_buffers(ev) {
        for i in 0..<n {
            let b = bufs[i]
            if let p = b.Buffer { ingest(p, Int(b.Length)) }
        }
    }
    return 0
}

let connCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_CONNECTION_EVENT>?) -> UInt32 = { conn, _, ev in
    guard let ev = ev else { return 0 }
    switch ev.pointee.Type {
    case QUIC_CONNECTION_EVENT_CONNECTED:
        var stream: OpaquePointer?
        _ = gApi.pointee.StreamOpen(conn, QUIC_STREAM_OPEN_FLAG_NONE, streamCb, nil, &stream)
        _ = gApi.pointee.StreamStart(stream, QUIC_STREAM_START_FLAG_IMMEDIATE)
        gAttach.withUnsafeMutableBufferPointer { bp in
            gAttachBuf.Length = UInt32(bp.count)
            gAttachBuf.Buffer = bp.baseAddress
            _ = gApi.pointee.StreamSend(stream, &gAttachBuf, 1, QUIC_SEND_FLAG_NONE, nil)
        }
    case QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE:
        gSem.signal()
    default: break
    }
    return 0
}

let args = CommandLine.arguments
let host: String
let port: UInt16
let session: String
let key: String
if args.count == 2, args[1] == "--bootstrap" {
    // Parse the helper's `FANTASTTY_REMOTE …` bootstrap line from stdin — the production path
    // (launch-or-resume prints this line), using the tested InsanittyCore parser.
    guard let line = readLine(strippingNewline: true),
          let boot = try? RemoteBootstrapLine.parse(line) else {
        FileHandle.standardError.write(Data("quic-client: could not parse FANTASTTY_REMOTE bootstrap line from stdin\n".utf8)); exit(2)
    }
    host = boot.host; port = boot.port; session = boot.session; key = boot.key
} else if args.count == 5, let p = UInt16(args[2]) {
    host = args[1]; port = p; session = args[3]; key = args[4]
} else {
    FileHandle.standardError.write(Data("usage: quic-client <host> <port> <session> <key>  |  quic-client --bootstrap  (FANTASTTY_REMOTE line on stdin)\n".utf8)); exit(2)
}
gAttach = Array("{\"session\":\"\(session)\",\"key\":\"\(key)\"}\n".utf8)

var apiRaw: UnsafeRawPointer?
guard MsQuicOpenVersion(2, &apiRaw) == 0, let raw = apiRaw else { fatalError("MsQuicOpen failed") }
gApi = raw.assumingMemoryBound(to: QUIC_API_TABLE.self)

var reg: OpaquePointer?
_ = gApi.pointee.RegistrationOpen(nil, &reg)

var config: OpaquePointer?
let alpn = Array("fantastty-remote-engine-v1".utf8)
alpn.withUnsafeBufferPointer { ap in
    var alpnBuf = QUIC_BUFFER(Length: UInt32(ap.count), Buffer: UnsafeMutablePointer(mutating: ap.baseAddress))
    _ = gApi.pointee.ConfigurationOpen(reg, &alpnBuf, 1, nil, 0, nil, &config)
}

var cred = QUIC_CREDENTIAL_CONFIG()
cred.Type = QUIC_CREDENTIAL_TYPE_NONE
cred.Flags = QUIC_CREDENTIAL_FLAGS(rawValue: QUIC_CREDENTIAL_FLAG_CLIENT.rawValue | QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION.rawValue)
_ = gApi.pointee.ConfigurationLoadCredential(config, &cred)

var conn: OpaquePointer?
_ = gApi.pointee.ConnectionOpen(reg, connCb, nil, &conn)
_ = host.withCString { hp in gApi.pointee.ConnectionStart(conn, config, UInt16(0), hp, port) }

_ = gSem.wait(timeout: .now() + 12)
gLock.lock(); let result = gResult; let count = gReceived.count; gLock.unlock()
if let result = result { print(result); exit(0) }
print("native client: no keyframe decoded (\(count) bytes received)"); exit(1)
