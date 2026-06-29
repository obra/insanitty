// tmux control-mode (`tmux -CC`) client. Spawns `tmux -CC attach` in a PTY (ins_pty_spawn —
// tmux requires a real tty), reads the control protocol on the GTK main loop (g_unix_fd_add,
// so no threads/marshaling), parses it (InsanittyCore.TmuxControlParser), and renders panes by
// injecting %output into silent Ghostty surfaces. Window/pane structure is surfaced to a bridge
// via callbacks so the app can mirror it into tabs/splits.
import CGhostty
import Foundation
#if canImport(Glibc)
import Glibc
#endif

final class TmuxControlClient {
    let session: String
    private(set) var masterFD: Int32 = -1
    private var pid: pid_t = 0
    private var partial: [UInt8] = []
    private var loggedRender = false
    /// The pane keystrokes are routed to (the last pane to produce output / become active).
    private(set) var activePane: Int?
    /// Fallback pane (queried from tmux up front) so input works before the first %output.
    var defaultPane: Int?
    /// The pane to route keystrokes to right now.
    var inputPane: Int? { activePane ?? defaultPane }
    /// The window size (cells) reported to tmux via refresh-client, so panes match the surfaces.
    var sizeCols = 110
    var sizeRows = 38

    /// Look up or create the surface a pane's output should be injected into (main thread).
    var surfaceForPane: ((_ pane: Int) -> OpaquePointer?)?
    /// A window's pane layout changed — the bridge (re)builds that window's tab/split tree.
    var onLayout: ((_ window: Int, _ layout: TmuxLayoutNode) -> Void)?
    /// A window closed.
    var onWindowClose: ((_ window: Int) -> Void)?

    init(session: String) { self.session = session }

    /// Spawn `tmux -CC attach-session -t <session>` in a PTY and start reading on the main loop.
    @discardableResult
    func start() -> Bool {
        let args: [String] = ["tmux", "-CC", "attach-session", "-t", session]
        var cargv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargv.append(nil)
        defer { for p in cargv where p != nil { free(p) } }
        masterFD = cargv.withUnsafeMutableBufferPointer { ins_pty_spawn($0.baseAddress, &pid) }
        guard masterFD >= 0 else {
            FileHandle.standardError.write(Data("tmux-cc: spawn failed for \(session)\n".utf8)); return false
        }
        let retained = Unmanaged.passRetained(self).toOpaque()
        g_unix_fd_add(masterFD, G_IO_IN, tmuxFDReadable, retained)
        // Tell tmux this control client's size so it sizes the window/panes to match the surfaces
        // (a detached session is tiny, and a -CC client's pty size doesn't drive the window).
        send("refresh-client -C \(sizeCols)x\(sizeRows)")
        FileHandle.standardError.write(Data("tmux-cc: attached \(session) (fd \(masterFD))\n".utf8))
        return true
    }

    /// Write a control command (e.g. `send-keys -t %1 -H 61`) to tmux.
    func send(_ command: String) {
        guard masterFD >= 0 else { return }
        let line = command + "\n"
        _ = line.withCString { write(masterFD, $0, strlen($0)) }
    }

    /// Forward raw input bytes to a pane (`send-keys -t %<pane> -H <hex>`).
    func sendKeys(pane: Int, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        send("send-keys -t %\(pane) -H \(hex)")
    }

    /// Main-thread fd-readable handler. Returns false to stop watching (EOF / hangup).
    func handleReadable(_ condition: GIOCondition) -> Bool {
        if condition.rawValue & G_IO_HUP.rawValue != 0 { return false }
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(masterFD, &buf, buf.count)
        if n <= 0 { return false }
        partial.append(contentsOf: buf[0..<Int(n)])
        while let nl = partial.firstIndex(of: 0x0A) {
            let lineBytes = Array(partial[0..<nl])
            partial.removeSubrange(0...nl)
            handleLine(String(decoding: lineBytes, as: UTF8.self))
        }
        return true
    }

    private func handleLine(_ line: String) {
        switch TmuxControlParser.parse(line: line) {
        case .output(let pane, let bytes):
            if activePane == nil { activePane = pane }
            guard let surface = surfaceForPane?(pane), !bytes.isEmpty else { return }
            bytes.withUnsafeBytes { raw in
                insanitty_surface_inject_output(
                    P(surface), raw.bindMemory(to: CChar.self).baseAddress, bytes.count)
            }
            if !loggedRender {
                loggedRender = true
                FileHandle.standardError.write(Data("tmux-cc: rendered \(bytes.count) bytes from pane %\(pane)\n".utf8))
            }
        case .layoutChange(let window, let layout):
            if let tree = TmuxLayoutParser.parse(layout) { onLayout?(window, tree) }
        case .windowClose(let window):
            onWindowClose?(window)
        case .windowPaneChanged(_, let pane):
            activePane = pane
        default:
            break
        }
    }
}

/// C trampoline for g_unix_fd_add. Releases the retained client when the source ends.
let tmuxFDReadable: @convention(c) (Int32, GIOCondition, UnsafeMutableRawPointer?) -> gboolean = { _, condition, ud in
    guard let ud = ud else { return 0 }
    let client = Unmanaged<TmuxControlClient>.fromOpaque(ud).takeUnretainedValue()
    if client.handleReadable(condition) { return 1 }
    Unmanaged<TmuxControlClient>.fromOpaque(ud).release()
    return 0
}
