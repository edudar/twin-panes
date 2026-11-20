# Filer

A native macOS file manager for Apple Silicon, starting with a binary file
viewer/editor for files up to 4 GB. Work in progress; see [docs/PLAN.md](docs/PLAN.md).

Requirements: macOS 15 or later, Apple Silicon, Xcode 16 or later.

## Layout

- `Package.swift`, `Sources/`, `Tests/` — one Swift package with every library target
  (`FilerCore`, `WorkspaceKit`, `HexViewKit`, `TextEditKit`, `EditorKit`, `SandboxProbe`).
- `App/` — the thin Xcode app target (`Filer.xcodeproj`), entitlements and app glue.

## Build and test

```bash
swift test
```

```bash
xcodebuild -project App/Filer.xcodeproj -scheme Filer -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build
```

```bash
build/DerivedData/Build/Products/Debug/Filer.app/Contents/MacOS/Filer --smoke-test
```

```bash
swift format lint --strict --recursive Package.swift Sources Tests App/Filer
```

## License

Apache-2.0. See [LICENSE](LICENSE).
