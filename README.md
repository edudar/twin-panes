# Twin Panes

A native macOS file manager for Apple Silicon, starting with a binary file
viewer/editor for files up to 4 GB. Work in progress; see [docs/PLAN.md](docs/PLAN.md).

Requirements: macOS 15 or later, Apple Silicon, Xcode 16 or later.

## Layout

- `TwinPanes.xcodeproj` — the thin app target. Open this in Xcode and run the **TwinPanes** scheme.
- `TwinPanes/` — app sources (entry point, menus, placeholder items, smoke test) and
  `AppIcon.icon`, the Icon Composer app icon (preview: `docs/assets/app-icon-appearances.png`).
- `Config/` — build settings (`.xcconfig`) and entitlements.
- `TwinPanesKit/` — one Swift package with every library target (`TwinPanesCore`, `WorkspaceKit`,
  `HexViewKit`, `TextEditKit`, `EditorKit`, `SandboxProbe`) and their tests.

## Build and test

```bash
swift test --package-path TwinPanesKit
```

```bash
xcodebuild -project TwinPanes.xcodeproj -scheme TwinPanes -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

```bash
build/DerivedData/Build/Products/Debug/Twin\ Panes.app/Contents/MacOS/Twin\ Panes --smoke-test
```

```bash
swift format lint --strict --recursive TwinPanesKit TwinPanes
```

## License

Apache-2.0. See [LICENSE](LICENSE).
