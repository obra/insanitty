//! Minimal C ABI to embed the Ghostty GTK terminal surface into a host GTK4
//! application (insanitty). The host owns its window/chrome; this TU owns the
//! libghostty App, the GhosttyApplication singleton, and the integrated run loop.
//!
//! Lives at src/ level (not under apprt/gtk/) so its module root is src/, matching
//! the exe — Ghostty's files import across src/ and a deeper root rejects that.
//! See docs/research/11-spikeA-embedding-plan.md.
const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gtk = @import("gtk");
const state = &@import("global.zig").state;
const CoreApp = @import("App.zig");
const apprt = @import("apprt.zig");
const Application = @import("apprt/gtk/class/application.zig").Application;
const Surface = @import("apprt/gtk/class/surface.zig").Surface;

var core_app: *CoreApp = undefined;
var rt_app: apprt.App = undefined;

/// Stand up global state, the core app, and the GhosttyApplication, and register
/// it so Application.default() works and compiled-in resources resolve. Returns
/// the GApplication* the host builds its AdwApplicationWindow from (null on error).
export fn insanitty_app_init() ?*anyopaque {
    state.init() catch return null;
    core_app = CoreApp.create(state.alloc) catch return null;
    rt_app.init(core_app, .{}) catch return null;
    var err: ?*glib.Error = null;
    if (rt_app.app.as(gio.Application).register(null, &err) == 0) {
        if (err) |e| e.free();
        return null;
    }
    return @ptrCast(rt_app.app.as(gio.Application));
}

/// Create a terminal surface widget. Parent it into any GtkWidget container; the
/// terminal (pty + renderer) spawns lazily on first realize+resize. Returns GtkWidget*.
export fn insanitty_surface_new() ?*anyopaque {
    const surface = Surface.new(.none);
    return @ptrCast(surface.as(gtk.Widget));
}

/// Like insanitty_surface_new but runs `cmd` (shell-expanded) instead of the default
/// shell — used for tmux-backed workspaces (`tmux new-session -A -s …`). The command is
/// cloned by Surface.new, so the caller's buffer need not outlive the call.
export fn insanitty_surface_new_command(cmd: [*:0]const u8) ?*anyopaque {
    const surface = Surface.new(.{ .command = .{ .shell = std.mem.span(cmd) } });
    return @ptrCast(surface.as(gtk.Widget));
}

/// Inject raw terminal output into a surface's VT parser, bypassing the PTY. This is the
/// render path for tmux control-mode `%output` and for painting remote content. `widget`
/// is the GtkWidget* returned by insanitty_surface_new (a GhosttySurface).
export fn insanitty_surface_inject_output(widget: ?*anyopaque, bytes: [*]const u8, len: usize) void {
    const w = widget orelse return;
    const surface: *Surface = @ptrCast(@alignCast(w));
    const core = surface.core() orelse return;
    core.io.processOutput(bytes[0..len]);
}

/// Run Ghostty's integrated event loop (pumps core_app.tick so the renderer draws).
/// Blocks until quit.
export fn insanitty_app_run() void {
    rt_app.run() catch |e| std.log.err("insanitty run failed: {}", .{e});
}

/// Begin app shutdown from the host.
export fn insanitty_app_quit() void {
    rt_app.app.quit();
}
