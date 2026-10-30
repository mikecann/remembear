# Agent guidance for Recall It

Recall It is a native macOS 14+ menu bar app, part of Mikerosoft, that replaces ChatGPT Desktop's Computer History for Mike. It records the window in front from a screenshot read by on-device text recognition (Vision), never the Accessibility API's window contents, writes 10-minute and 6-hour Markdown summaries with `claude -p` on Mike's subscription, and Agent Archive backs those up from the summaries folder. Swift 6 with AppKit and ApplicationServices, no third-party dependencies.

## Rules

- Privacy first. Every privacy check (`PrivacyRules.allows`, `allowsBrowser`) runs before a window is captured and again after, before an event is built. Private browser windows, password managers and excluded apps and sites must never reach the events folder, and screen text always goes through `Privacy.redactScreenText`. When in doubt, leave it out: a browser window that can't be confirmed as normal over AppleScript isn't recorded.
- Never read other apps' windows through the Accessibility API (tree walks, element-at-point, focused-element polling) or turn on `AXManualAccessibility`/`AXEnhancedUserInterface`: each read runs on the target app's main thread, and it made Threadbear and Chrome lag (30 Oct 2026). Screenshots and the window list cost the app nothing. Accessibility trust is only for the global key monitor.
- Screenshots stay in memory and are dropped once read. Never write one to disk or send one anywhere.
- Use test-first development for non-trivial changes. Keep logic in `RecallItCore` so it can be tested without permissions.
- Summary files must keep Codex's file name format and frontmatter (`title`, `description`, `applications` on single lines), because Agent Archive parses them (`shared/computerHistory.ts` in the agent-archive repo).
- The `claude` call must keep `--tools ""`, `--strict-mcp-config`, `--setting-sources ""` and `--no-session-persistence`: no tools, no hooks or CLAUDE.md, and no transcript that would turn up in Agent Archive as a thread.
- Always use `restart.sh` to rebuild and relaunch. Keep `com.mikerosoft.recall-it` and its designated requirement stable so the Accessibility grant survives rebuilds.
- Raw events stay 48 hours. Summaries are never deleted except by "Forget the Last Hour".
- No em dashes in copy.

## Code layout

- `Sources/RecallItCore`: `Event.swift` (event model, JSONL), `Privacy.swift` (rules, browser checks, secret masking for screen text), `ScreenText.swift` (recognised text to lines), `TimeWindow.swift` (UTC windows, file names), `Digest.swift` (events to compact prompt text, deduped and budgeted), `Prompts.swift`, `SummaryFile.swift` (parse the reply, render Markdown), `Schedule.swift` (what's due), `Settings.swift`.
- `Sources/RecallIt`: `AppDelegate.swift` (menu), `Recorder.swift` (window polling every 2 s from the window list, window capture with ScreenCaptureKit and text recognition with Vision, browser checks over AppleScript, Return and shortcuts), `EventStore.swift`, `Summarizer.swift` (passes every minute, `claude -p`), `Support.swift` (paths, log, AX helpers).
- `~/Library/Application Support/Recall It/{events,summaries,claude-cwd}`, `~/Library/Logs/recall-it.log`.

## Build and verify

```bash
swift build
swift test
bash -n restart.sh uninstall.sh
bash restart.sh
tail -f ~/Library/Logs/recall-it.log
```

In a sandbox, keep module caches inside the clone and use `--disable-sandbox`, as `restart.sh` does.

After a recorder change, check by hand: switch apps and tabs, open a Chrome incognito window and confirm nothing from it lands in `events/`, put an environment variable on screen (`echo FOO_BAR=secret` in Terminal) and check it's masked, send a Slack message and check the submit event and the text that follows, then wait for the next 10-minute summary in the log.
