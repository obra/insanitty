import CGhostty

// Return-type-overloaded pointer casts: GTK functions import with mixed pointer types
// (OpaquePointer vs UnsafeMutablePointer<GtkWindow>). Store handles as OpaquePointer
// and let each call site resolve to whatever the callee wants.
@inline(__always) func P<T>(_ p: OpaquePointer?) -> UnsafeMutablePointer<T>? { p.map { UnsafeMutablePointer<T>($0) } }
@inline(__always) func P(_ p: OpaquePointer?) -> OpaquePointer? { p }
@inline(__always) func OP<T>(_ p: UnsafeMutablePointer<T>?) -> OpaquePointer? { p.map(OpaquePointer.init) }
@inline(__always) func OP(_ p: OpaquePointer?) -> OpaquePointer? { p }
@inline(__always) func raw(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? { p.map { UnsafeMutableRawPointer($0) } }

@discardableResult
func onSignal(
    _ instance: OpaquePointer?,
    _ signal: String,
    _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
    userData: UnsafeMutableRawPointer? = nil
) -> gulong {
    ins_signal_connect(raw(instance), signal, callback, userData)
}
