// swift-tools-version: 6.0
// TwinPanesKit: every library target of Twin Panes (D20). The app target lives in
// TwinPanes.xcodeproj at the repository root and links these products. Dependencies point
// strictly down (PLAN.md §4):
//
//   Twin Panes app (TwinPanes.xcodeproj, TwinPanes/)
//    ├─ EditorKit ─┬─ HexViewKit ─┐
//    │             └─ TextEditKit ┤
//    └─────────────────────────── WorkspaceKit ── TwinPanesCore
//
// BrowserKit joins in M4. SandboxProbe is the M0 sandbox spike (§5); only the app's
// Debug menu uses it.

import PackageDescription

let package = Package(
    name: "TwinPanesKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TwinPanesCore", targets: ["TwinPanesCore"]),
        .library(name: "WorkspaceKit", targets: ["WorkspaceKit"]),
        .library(name: "HexViewKit", targets: ["HexViewKit"]),
        .library(name: "TextEditKit", targets: ["TextEditKit"]),
        .library(name: "EditorKit", targets: ["EditorKit"]),
        .library(name: "SandboxProbe", targets: ["SandboxProbe"]),
    ],
    targets: [
        // No UI imports allowed here.
        .target(name: "TwinPanesCore"),
        .target(name: "WorkspaceKit", dependencies: ["TwinPanesCore"]),
        .target(name: "HexViewKit", dependencies: ["WorkspaceKit", "TwinPanesCore"]),
        .target(name: "TextEditKit", dependencies: ["WorkspaceKit", "TwinPanesCore"]),
        .target(
            name: "EditorKit",
            dependencies: ["HexViewKit", "TextEditKit", "WorkspaceKit", "TwinPanesCore"]),
        .target(name: "SandboxProbe"),

        .testTarget(name: "TwinPanesCoreTests", dependencies: ["TwinPanesCore"]),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
        .testTarget(name: "SandboxProbeTests", dependencies: ["SandboxProbe"]),
    ]
)
