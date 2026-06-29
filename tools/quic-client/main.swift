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
let gSem = DispatchSemaphore(value: 0)

func gotKeyframe() -> Bool { String(decoding: gReceived, as: UTF8.self).contains("\"paneKeyframe\"") }

let streamCb: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<QUIC_STREAM_EVENT>?) -> UInt32 = { _, _, ev in
    guard let ev = ev else { return 0 }
    if ev.pointee.Type == QUIC_STREAM_EVENT_RECEIVE {
        let n = Int(ins_recv_count(ev))
        if let bufs = ins_recv_buffers(ev) {
            for i in 0..<n {
                let b = bufs[i]
                if let p = b.Buffer { gReceived.append(p, count: Int(b.Length)) }
            }
        }
        if gotKeyframe() { gSem.signal() }
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
guard args.count == 5, let port = UInt16(args[2]) else {
    FileHandle.standardError.write(Data("usage: quic-client <host> <port> <session> <key>\n".utf8)); exit(2)
}
gAttach = Array("{\"session\":\"\(args[3])\",\"key\":\"\(args[4])\"}\n".utf8)

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
_ = args[1].withCString { hp in gApi.pointee.ConnectionStart(conn, config, UInt16(0), hp, port) }

if gSem.wait(timeout: .now() + 12) == .timedOut {
    FileHandle.standardError.write(Data("timed out; received \(gReceived.count) bytes\n".utf8))
}

var ok = false
for line in String(decoding: gReceived, as: UTF8.self).split(separator: "\n").map(String.init) {
    if let msg = try? RemoteGridProtocol.decode(line: line), case let .paneKeyframe(kf) = msg {
        print("NATIVE-QUIC-OK: native Swift client got paneKeyframe over QUIC — grid=\(kf.gridSize.columns)x\(kf.gridSize.rows), rows=\(kf.rows.count)")
        ok = true; break
    }
}
if !ok { print("native client: no keyframe decoded (\(gReceived.count) bytes received)") }
exit(ok ? 0 : 1)
