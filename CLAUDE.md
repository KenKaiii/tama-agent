# Tama

macOS menu-bar AI assistant with floating prompt panel (⌥Space), agentic tool loop, voice calls with TTS, browser automation, and animated Rive mascot. Supports multiple providers (Claude, OpenAI, Moonshot, MiniMax, Xiaomi). Swift 6, macOS 15+, no dock icon.

## Project Structure

```
Tama/Sources/
├── TamaApp.swift                  # @main entry, menu bar extra, AppDelegate
├── AI/                            # LLM integration (multi-provider)
│   ├── ClaudeService.swift        # Claude HTTP client, streaming, OAuth tokens
│   ├── ClaudeOAuth.swift          # Claude OAuth2 PKCE login flow
│   ├── ClaudeCredentials.swift    # Encrypted credential persistence
│   ├── ClaudeModels.swift         # Claude API request/response types
│   ├── AgentLoop.swift            # Multi-turn tool execution loop (max 50 turns)
│   ├── StreamParser.swift         # Claude SSE stream parser
│   ├── CodexRequestBuilder.swift  # OpenAI/Codex request builder
│   ├── CodexStreamParser.swift    # OpenAI/Codex stream parser
│   ├── OpenAIOAuth.swift          # OpenAI OAuth flow
│   ├── OpenAIStreamParser.swift   # OpenAI stream parser
│   ├── ModelRegistry.swift        # Multi-model registry
│   ├── ProviderStore.swift        # Multi-provider management
│   ├── SystemPrompt.swift         # Base system prompt
│   ├── CallSystemPrompt.swift     # Voice call system prompt
│   └── Tools/                     # Agent tool implementations
│       ├── AgentTool.swift        # Tool protocol + ToolRegistry
│       ├── BashTool.swift         # Shell command execution
│       ├── ReadTool.swift         # File reading (cat -n style)
│       ├── WriteTool.swift        # File writing
│       ├── EditTool.swift         # Search-and-replace editing
│       ├── GrepTool.swift         # Regex file search
│       ├── FindTool.swift         # Glob file finder
│       ├── LsTool.swift           # Directory listing
│       ├── WebFetchTool.swift     # URL fetcher with SSRF protection
│       ├── WebSearchTool.swift    # Web search
│       ├── CreateReminderTool.swift   # Scheduled reminder notifications
│       ├── CreateRoutineTool.swift    # Scheduled LLM-triggered routines
│       ├── ListSchedulesTool.swift    # List active schedules
│       ├── DeleteScheduleTool.swift   # Delete a schedule by name
│       ├── DismissTool.swift      # Dismiss panel
│       ├── EndCallTool.swift      # End voice call
│       ├── SkillTool.swift        # Skill management
│       ├── ScreenshotTool.swift   # Full-screen capture for vision-capable models
│       ├── TaskTool.swift         # Task management
│       └── Browser/               # Browser automation via CDP
│           ├── BrowserManager.swift, BrowserTool.swift
│           ├── CDPConnection.swift, ChromiumManager.swift
├── Extensions/                    # Swift extensions (NSScreen+Notch)
├── Login/                         # OAuth login window + SwiftUI view
├── Mascot/                        # Animated Rive mascot (idle/typing/waiting/responding)
├── Notifications/                 # Notch-based notification system (Dynamic Island-style)
├── Onboarding/                    # First-launch onboarding flow
├── Permissions/                   # Accessibility & Full Disk Access checker
├── PromptPanel/                   # Floating chat panel UI
│   ├── FloatingPanel.swift        # NSPanel subclass, streaming display
│   ├── PromptPanelController.swift # Panel lifecycle, hotkey, submit handling
│   ├── MarkdownRenderer.swift     # Markdown → NSAttributedString
│   └── ...                        # Response views, image preview, error handling, list views
├── Scheduler/                     # Reminder & routine scheduling system
├── Sessions/                      # Chat session persistence (ChatSession, SessionStore)
├── Skills/                        # Custom skill definitions and management
├── Tasks/                         # Task items and management UI
├── Tools/                         # Panel tools (clipboard history, keep awake, night shift)
├── UI/                            # Shared components (GlassButton, MenuBarIcon, AnimatedTabBar)
├── Update/                        # In-app update system (AppUpdater, UpdateView)
├── Utilities/                     # Helpers (DownloadHelper)
└── Voice/                         # Voice calls with TTS (Kokoro), speech recognition
```

## Tech Stack

- **Language**: Swift 6.0 (strict concurrency)
- **Platform**: macOS 15+, arm64 only, LSUIElement menu-bar app
- **UI**: AppKit (NSPanel, NSTextView) + SwiftUI
- **Dependencies**: RiveRuntime (animations), Highlightr (syntax), KokoroSwift (TTS), MLX + MLXUtilsLibrary (on-device ML)
- **Build**: XcodeGen (`project.yml` → .xcodeproj), SPM for packages
- **CI**: GitHub Actions (`release.yml`) — build, codesign, notarize, DMG, GitHub Release
- **Logging**: `os.Logger` (subsystem `com.unstablemind.tama`)

## Build & Quality Commands

**To run / launch / "run dev" / build-and-run, ALWAYS use `./scripts/dev.sh`.** Never `open` the DerivedData `.app` directly and never tell the user to run from Xcode. The script builds, installs to `~/Applications/Tama.app` (a stable path so TCC permissions persist across rebuilds), and launches. Running from DerivedData causes permissions to appear "reset" on every rebuild because macOS keys TCC to the binary path + cdhash.

```bash
./scripts/dev.sh                # build + install to ~/Applications/Tama.app + launch (default for "run")
./scripts/dev.sh --no-build     # relaunch the installed copy without rebuilding
./scripts/dev.sh --reset-tcc    # nuke Tama's TCC entries (forces fresh permission prompts)

xcodegen generate                                              # Regenerate .xcodeproj from project.yml
xcodebuild -project Tama.xcodeproj -scheme Tama -configuration Debug build  # Build only (no install / launch)
swiftlint lint --config .swiftlint.yml                         # Lint
swiftformat --lint --config .swiftformat Tama/Sources          # Format check
swiftformat --config .swiftformat Tama/Sources                 # Format auto-fix
```

## Logging

All logging uses `os.Logger` with subsystem `com.unstablemind.tama`. Categories match file purpose (e.g. `agent`, `claude`, `tool.bash`, `scheduler`, `controller`, `panel`).

```bash
log stream --predicate 'subsystem == "com.unstablemind.tama"' --level debug           # All logs
log stream --predicate 'subsystem == "com.unstablemind.tama" AND category == "agent"' --level debug  # Agent only
log stream --predicate 'subsystem == "com.unstablemind.tama" AND category BEGINSWITH "tool."' --level debug  # Tools only

# Voice call diagnosis — all pipeline logs (listen → agent → TTS → playback)
log stream --predicate 'subsystem == "com.unstablemind.tama" AND category IN {"callsession", "callmetrics", "voice", "speech", "kokoro", "agent"}' --style compact

# Just the per-turn metric summaries with ⚠️ SLOW warnings
log stream --predicate 'subsystem == "com.unstablemind.tama" AND category == "callmetrics"' --style compact

# Convenience: `scripts/call-logs.sh` streams the full call pipeline
```

## Code Rules

- One component per file, file name matches primary type
- `@MainActor` on all UI-touching classes; tools are `@unchecked Sendable`
- Errors as `LocalizedError` enums scoped to their type
- Use `os.Logger` for all logging — never `print()` or `NSLog()`
- 4-space indent, 120 char max line width, trailing commas always
- No dead code, no TODOs, no commented-out code
