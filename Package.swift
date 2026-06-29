// swift-tools-version: 6.0
// insanitty — native Linux port of Fantastty. See docs/SPEC.md and docs/IMPLEMENTATION-PROPOSAL.md.
//
// This package is the portable, GTK-free logic library (InsanittyCore) and its tests. The GTK4
// application itself lives in app/ and is built by scripts/build-app.sh (it links the forked
// Ghostty GTK engine via app/CGhostty), not by SwiftPM.
import PackageDescription

let package = Package(
    name: "insanitty",
    targets: [
        // Platform-neutral logic ported from Fantastty (workspace names, remote wire types,
        // split geometry, Linear URLs, layout persistence).
        .target(name: "InsanittyCore", path: "Sources/InsanittyCore"),
        .testTarget(
            name: "InsanittyCoreTests",
            dependencies: ["InsanittyCore"],
            path: "Tests/InsanittyCoreTests"
        ),
    ]
)
