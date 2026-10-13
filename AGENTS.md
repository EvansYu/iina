# AGENTS.md — iina project entry

Read [GLOBAL_AGENTS.md](GLOBAL_AGENTS.md), [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Verified project facts

- Project: iina, a native macOS media player using mpv.
- Stack: Swift (language mode 5.0), AppKit, Objective-C/C bridging, libmpv, FFmpeg, JavaScript plugin integration, Xcode and Swift Package Manager.
- Current deployment configuration: macOS 12 (`Configs/Deployment.xcconfig`). The older README feature summary says 11.0+; use configuration for this checkout's build target.
- Dependencies: `./other/download_libs.sh`; see README for options and manual build alternatives.
- CI build: `xcodebuild -project iina.xcodeproj ONLY_ACTIVE_ARCH=NO -scheme iina -derivedDataPath . -configuration Nightly`.
- Automated test command: not identified. The project contains no XCTest target and the shared iina scheme declares no explicit testables. CI builds and separately checks spelling.
- Initialization date: 2026-10-13.

## Navigation and execution

1. Consult [project CodeMap](mydocs/codemap/2026-10-13_00-23_iina项目总图.md) for entry points and boundaries.
2. When the index exists, use CodeGraph before code searches or reads; see the shared rules. Check index freshness before relying on results.
3. Identify affected modules and validation before implementation. Use `sdd-riper-one-light` for medium or larger development work.
4. Keep playback logic in PlayerCore, direct mpv access in MPVController/VideoView, and window lifecycle logic in MainWindowController.
5. Use [Mermaid rules](docs/knowledge/mermaid-rules.md) for diagrams and [Karpathy guidelines](docs/knowledge/karpathy-guidelines-en.md) for focused changes.

## User skill location preference

Create future skill source files under `/Users/yuhb/work/aiProject/greenfire-agents/agents/skills/<skill-name>/` unless instructed otherwise. Do not copy or link them into installed skill directories unless installation is explicitly requested.

## Local verification boundary

During initialization, `xcodebuild -version` failed because the active developer directory was `/Library/Developer/CommandLineTools`. Application build and runtime checks remain unverified until a full Xcode installation is selected. No test command is invented to fill this gap.
