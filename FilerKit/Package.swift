// swift-tools-version: 6.0
// FilerKit: every library target of Filer (D20). The app target lives in
// Filer.xcodeproj at the repository root and links these products. Dependencies point
// strictly down (PLAN.md §4):
//
//   Filer app (Filer.xcodeproj, Filer/)
//    ├─ EditorKit ─┬─ HexViewKit ─┐
//    │             └─ TextEditKit ┤
//    └─────────────────────────── WorkspaceKit ── FilerCore
//
// BrowserKit joins in M4. SandboxProbe is the M0 sandbox spike (§5); only the app's
// Debug menu uses it.

import PackageDescription

let package = Package(
    name: "FilerKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FilerCore", targets: ["FilerCore"]),
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
        .library(name: "HexViewKit", targets: ["HexViewKit"]),
        .library(name: "TextEditKit", targets: ["TextEditKit"]),
        .library(name: "EditorKit", targets: ["EditorKit"]),
        .library(name: "SandboxProbe", targets: ["SandboxProbe"]),
    ],
    targets: [
        // No UI imports allowed here.
        .target(name: "FilerCore"),
        .target(name: "WorkspaceKit", dependencies: ["FilerCore"]),
        .target(name: "HexViewKit", dependencies: ["WorkspaceKit", "FilerCore"]),
        .target(name: "TextEditKit", dependencies: ["WorkspaceKit", "FilerCore"]),
        .target(
            name: "EditorKit",
            dependencies: ["HexViewKit", "TextEditKit", "WorkspaceKit", "FilerCore"]),
        .target(name: "SandboxProbe"),

        .testTarget(name: "FilerCoreTests", dependencies: ["FilerCore"]),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
        .testTarget(name: "SandboxProbeTests", dependencies: ["SandboxProbe"]),
    ]
)
