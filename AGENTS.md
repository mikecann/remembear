# Agent guidance for RememBear

RememBear is a native macOS 14+ menu bar app, part of Mikerosoft, that replaces ChatGPT Desktop's Computer History for Mike. It records the window in front from a screenshot read by on-device text recognition (Vision), never the Accessibility API's window contents, writes 10-minute and 6-hour Markdown summaries with `claude -p` on Mike's subscription, and Agent Archive backs those up from the summaries folder. Swift 6 with AppKit and ApplicationServices, no third-party dependencies.

## Rules

- Privacy first. Every privacy check (`PrivacyRules.allows`, `allowsBrowser`) runs before a window is captured and again after, before an event is built. Private browser windows, password managers (apps and web vaults), terminals and excluded apps and sites must never reach the events folder, and screen text always goes through `Privacy.redactScreenText`. When in doubt, leave it out: a browser window that can't be confirmed as normal over AppleScript isn't recorded.
- Never read other apps' windows through the Accessibility API (tree walks, element-at-point, focused-element polling) or turn on `AXManualAccessibility`/`AXEnhancedUserInterface`: each read runs on the target app's main thread, and it made Threadbear and Chrome lag (30 Oct 2026). Screenshots and the window list cost the app nothing. Accessibility trust is only for the global key monitor.
- Screenshots stay in memory and are dropped once read and embedded. Never write one to disk or send one anywhere but the local embedder (127.0.0.1, token in embedder.json, 0600).
- Only captures that were recorded (passed every privacy check, wrote an event) get a search vector. `search.sqlite` holds vectors, metadata and a 400-character masked excerpt, kept `ScreenSearch.keepDays` (30); Forget the Last Hour clears it.
- The binary is also the `remembear search` command (linked into ~/.local/bin). Anything else run from a shell prints usage and exits: only launchd (Finder, Spotlight, login) starts the menu bar app, or a shell would become a second copy of it.
- Use test-first development for non-trivial changes. Keep logic in `RememBearCore` so it can be tested without permissions.
- Summary files must keep Codex's file name format and frontmatter (`title`, `description`, `applications` on single lines), because Agent Archive parses them (`shared/computerHistory.ts` in the agent-archive repo).
- The `claude` call must keep `--tools ""`, `--strict-mcp-config`, `--setting-sources ""` and `--no-session-persistence`: no tools, no hooks or CLAUDE.md, and no transcript that would turn up in Agent Archive as a thread.
- Always use `restart.sh` to rebuild and relaunch. Keep `app.mikecann.remembear` and its designated requirement stable so the Accessibility grant survives rebuilds.
- Raw events stay 48 hours. Summaries are never deleted except by "Forget the Last Hour".
- No em dashes in copy.

## Code layout

- `Sources/RememBearCore`: `Event.swift` (event model, JSONL), `Privacy.swift` (rules, browser checks, secret masking for screen text), `ScreenText.swift` (recognised text to lines), `ScreenSearch.swift` (vectors, ranking, the search command's arguments), `Setup.swift` (permission states), `TimeWindow.swift` (UTC windows, file names), `Digest.swift` (events to compact prompt text, deduped and budgeted), `Prompts.swift`, `SummaryFile.swift` (parse the reply, render Markdown), `Schedule.swift` (what's due), `Settings.swift`.
- `Sources/RememBear`: `AppDelegate.swift` (menu), `Recorder.swift` (window polling every 2 s from the window list, window capture with ScreenCaptureKit and text recognition with Vision, browser checks over AppleScript, Return and shortcuts), `EventStore.swift`, `Summarizer.swift` (passes every minute, `claude -p`), `Support.swift` (paths, log), `Search.swift` (the embedder client, `ShotStore` over search.sqlite, `remembear search`), `SetupWindow.swift` (permissions).
- `~/Library/Application Support/RememBear/{events,summaries,claude-cwd}`, `~/Library/Logs/remembear.log`.

## Build and verify

```bash
swift build
swift test
bash -n restart.sh uninstall.sh
bash restart.sh
tail -f ~/Library/Logs/remembear.log
```

In a sandbox, keep module caches inside the clone and use `--disable-sandbox`, as `restart.sh` does.

After a recorder change, check by hand: switch apps and tabs, open a Chrome incognito window and confirm nothing from it lands in `events/`, bring Terminal to the front and confirm nothing from it lands in `events/`, put an environment variable on screen (`FOO_BAR=secret` in TextEdit) and check it's masked, send a Slack message and check the submit event and the text that follows, then wait for the next 10-minute summary in the log.

## Screenshot search

`embedder/` is a small Python server (sentence-transformers, `google/embeddinggemma-2`, fp16 on MPS) that RememBear starts on demand from `~/Library/Application Support/RememBear/embedder-venv`. Text queries use the model's "query" prompt; images go in at 768 px on the long side (about 0.2 s each on the M5). Change `embedder/pyproject.toml`, then `uv lock` in `embedder/` and `restart.sh`.
