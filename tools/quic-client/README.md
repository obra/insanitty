# quic-client — native Swift QUIC client (msquic)

insanitty's native remote-engine transport: binds **msquic** (built from source) and speaks
QUIC to the remote-engine helper directly — replacing the Go-probe subprocess bridge.

`main.swift` + `CMsQuic/` (module map) open msquic, configure ALPN `fantastty-remote-engine-v1`,
connect to the helper, send the `{session,key}` attach, read the reliable stream, and decode the
structured grid with `InsanittyCore.RemoteGridProtocol`.

Verified: `scripts/e2e-native-quic.sh` — the native client attaches over QUIC and decodes a
`paneKeyframe` (80x24, 24 rows) from the live helper.

Build: `tools/quic-client/build.sh` (needs msquic at $MSQUIC; see scripts and docs/STATUS.md).
Remaining: SPKI cert-pin verification in the PEER_CERTIFICATE_RECEIVED callback (currently
connects with NO_CERTIFICATE_VALIDATION); datagram deltas; predictive echo.
