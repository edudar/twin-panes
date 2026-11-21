# Filer

A native macOS file manager for Apple Silicon, starting with a binary file
viewer/editor for files up to 4 GB. Work in progress; see [docs/PLAN.md](docs/PLAN.md).

Requirements: macOS 15 or later, Apple Silicon, Xcode 16 or later.

## Layout

- `Filer.xcodeproj` — the thin app target. Open this in Xcode and run the **Filer** scheme.
- `Filer/` — app sources (entry point, menus, placeholder items, smoke test).
- `Config/` — build settings (`.xcconfig`) and entitlements.
- `FilerKit/` — one Swift package with every library target (`FilerCore`, `WorkspaceKit`,
  `HexViewKit`, `TextEditKit`, `EditorKit`, `SandboxProbe`) and their tests.

## Build and test

```bash
swift test --package-path FilerKit
```

```bash
xcodebuild -project Filer.xcodeproj -scheme Filer -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

```bash
build/DerivedData/Build/Products/Debug/Filer.app/Contents/MacOS/Filer --smoke-test
```

```bash
swift format lint --strict --recursive FilerKit Filer
```

## License

Apache-2.0. See [LICENSE](LICENSE).
