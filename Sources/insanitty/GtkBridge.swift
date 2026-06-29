import CAdw
import CInsanitty

// GTK's C functions import with inconsistent pointer types: some parameters are
// `OpaquePointer`, others `UnsafeMutablePointer<GtkWindow>` etc. (per how each struct is
// declared in the headers). These return-type-overloaded helpers let call sites pass a
// single stored `OpaquePointer` and resolve to whatever the callee expects.

/// To a call parameter: yields a typed pointer or an OpaquePointer as required.
@inline(__always) func P<T>(_ p: OpaquePointer?) -> UnsafeMutablePointer<T>? {
    p.map { UnsafeMutablePointer<T>($0) }
}
@inline(__always) func P(_ p: OpaquePointer?) -> OpaquePointer? { p }

/// Normalize a creation result (typed or opaque) to a stored `OpaquePointer`.
@inline(__always) func OP<T>(_ p: UnsafeMutablePointer<T>?) -> OpaquePointer? {
    p.map(OpaquePointer.init)
}
@inline(__always) func OP(_ p: OpaquePointer?) -> OpaquePointer? { p }

@inline(__always) func raw(_ p: OpaquePointer?) -> UnsafeMutableRawPointer? {
    p.map { UnsafeMutableRawPointer($0) }
}

/// Connect a no-capture C callback to a GObject signal (via the CInsanitty bridge,
/// which performs the `G_CALLBACK` cast that Swift can't express directly).
@discardableResult
func onSignal(
    _ instance: OpaquePointer?,
    _ signal: String,
    _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
    userData: UnsafeMutableRawPointer? = nil
) -> gulong {
    ins_signal_connect(raw(instance), signal, callback, userData)
}
