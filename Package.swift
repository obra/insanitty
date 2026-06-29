// swift-tools-version: 6.0
// insanitty — native Linux port of Fantastty. See docs/SPEC.md and docs/IMPLEMENTATION-PROPOSAL.md.
import PackageDescription

let package = Package(
    name: "insanitty",
    targets: [
        // System libraries: GTK4 + libadwaita, imported via a C module map.
        .systemLibrary(
            name: "CAdw",
            path: "Sources/CAdw",
            pkgConfig: "libadwaita-1",
            providers: [.apt(["libadwaita-1-dev", "libgtk-4-dev"])]
        ),
        // C glue: the (stubbed) shim to the Ghostty GTK build + small GObject signal helpers.
        // Depends on CAdw so the C sources see the GTK headers.
        .target(
            name: "CInsanitty",
            dependencies: ["CAdw"],
            path: "Sources/CInsanitty",
            publicHeadersPath: "include"
        ),
        // Platform-neutral logic ported from Fantastty (grows into the bulk of the app).
        .target(name: "InsanittyCore", path: "Sources/InsanittyCore"),

        // The application shell skeleton (GTK4/libadwaita chrome).
        .executableTarget(
            name: "insanitty",
            dependencies: ["CAdw", "CInsanitty", "InsanittyCore"],
            path: "Sources/insanitty"
        ),
        // Phase-0 Spike: the verified Swift↔GTK interop smoke test.
        .executableTarget(
            name: "spike-gtk-smoke",
            dependencies: ["CAdw"],
            path: "Sources/spike-gtk-smoke"
        ),

        .testTarget(
            name: "InsanittyCoreTests",
            dependencies: ["InsanittyCore"],
            path: "Tests/InsanittyCoreTests"
        ),
    ]
)
