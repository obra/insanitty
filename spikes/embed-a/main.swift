// Spike A: a Swift host that embeds a real Ghostty GTK terminal surface.
// Hosts Ghostty's GApplication via the libghostty-gtk shim, builds its OWN
// AdwApplicationWindow, parents one live GhosttySurface, and runs Ghostty's loop.
import CEmbed
import Foundation

@inline(__always) func P<T>(_ p: OpaquePointer?) -> UnsafeMutablePointer<T>? { p.map { UnsafeMutablePointer<T>($0) } }
@inline(__always) func P(_ p: OpaquePointer?) -> OpaquePointer? { p }
@inline(__always) func OP<T>(_ p: UnsafeMutablePointer<T>?) -> OpaquePointer? { p.map(OpaquePointer.init) }
@inline(__always) func OP(_ p: OpaquePointer?) -> OpaquePointer? { p }

func err(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }

guard let appRaw = insanitty_app_init() else { err("insanitty_app_init failed\n"); exit(1) }
let app = OP(appRaw)
print("insanitty: GApplication initialized")

let win = OP(adw_application_window_new(P(app)))
gtk_window_set_default_size(P(win), 960, 600)
gtk_window_set_title(P(win), "insanitty — embedded Ghostty terminal")

guard let termRaw = insanitty_surface_new() else { err("insanitty_surface_new failed\n"); exit(1) }
let term = OP(termRaw)
adw_application_window_set_content(P(win), P(term))
gtk_window_present(P(win))
print("insanitty: window presented with a live GhosttySurface")

// Headless safety: self-quit so CI/screenshot runs terminate.
let quit: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { _ in
    insanitty_app_quit()
    return 0 // G_SOURCE_REMOVE
}
g_timeout_add(25000, quit, nil)

insanitty_app_run()
print("insanitty: loop exited cleanly")
