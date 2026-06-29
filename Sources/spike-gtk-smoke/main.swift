// Phase-0 Spike (interop): proves Swift drives GTK4 + libadwaita via direct C interop.
// VERIFIED on the dev box: `gtk 4.14.5 / adw 1.5`, init OK, widget tree (GtkPaned) OK,
// AdwStyleManager OK — run headless under `xvfb-run -a`. See docs/STATUS.md.
import CAdw
import Foundation

print("gtk \(gtk_get_major_version()).\(gtk_get_minor_version()).\(gtk_get_micro_version())"
    + " / adw \(adw_get_major_version()).\(adw_get_minor_version())")

guard gtk_init_check() != 0 else {
    FileHandle.standardError.write(Data("gtk_init_check failed (no display)\n".utf8))
    exit(2)
}
adw_init()

let sm = adw_style_manager_get_default()
print("adw style_manager=\(sm != nil) dark=\(sm.map { adw_style_manager_get_dark($0) } ?? 0)")

// Build a real widget tree — the GtkPaned split substrate for Spike D.
let paned = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)
gtk_paned_set_start_child(OpaquePointer(paned), gtk_label_new("workspace"))
gtk_paned_set_end_child(OpaquePointer(paned), gtk_label_new("terminal"))
print("widget-tree-ok paned=\(paned != nil)")
print("SPIKE-GTK-SMOKE-OK")
