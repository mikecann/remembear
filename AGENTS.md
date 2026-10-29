# Agent guidance for Recall It

Recall It is a native macOS 14+ menu bar app, part of Mikerosoft, that replaces ChatGPT Desktop's Computer History for Mike. It records activity through the Accessibility API, writes 10-minute and 6-hour Markdown summaries with `claude -p` on Mike's subscription, and Agent Archive backs those up from the summaries folder. Swift 6 with AppKit and ApplicationServices, no third-party dependencies.

## Rules

- Privacy first. Every privacy check (`PrivacyRules.allows`) runs before an event is built or text is read into an event. Private browser windows, password managers, secure fields and excluded apps and sites must never reach the events folder. When in doubt, leave it out: a browser window with no readable title is treated as private.
- If a browser changes how it titles private windows, update `Privacy.isPrivateWindowTitle` and its test with the real title (check with `mitts windows <app>`).
- Use test-first development for non-trivial changes. Keep logic in `RecallItCore` so it can be tested without permissions.
- Summary files must keep Codex's file name format and frontmatter (`title`, `description`, `applications` on single lines), because Agent Archive parses them (`shared/computerHistory.ts` in the agent-archive repo).
- The `claude` call must keep `--tools ""`, `--strict-mcp-config`, `--setting-sources ""` and `--no-session-persistence`: no tools, no hooks or CLAUDE.md, and no transcript that would turn up in Agent Archive as a thread.
- Always use `restart.sh` to rebuild and relaunch. Keep `com.mikerosoft.recall-it` and its designated requirement stable so the Accessibility grant survives rebuilds.
- Raw events stay 48 hours. Summaries are never deleted except by "Forget the Last Hour".
- No em dashes in copy.

## Code layout

- `Sources/RecallItCore`: `Event.swift` (event model, JSONL), `Privacy.swift` (rules, private-window titles, secret masking), `TimeWindow.swift` (UTC windows, file names), `Digest.swift` (events to compact prompt text, deduped and budgeted), `Prompts.swift`, `SummaryFile.swift` (parse the reply, render Markdown), `Schedule.swift` (what's due), `Settings.swift`.
- `Sources/RecallIt`: `AppDelegate.swift` (menu), `Recorder.swift` (window polling every 2 s, clicks, Return, shortcuts), `EventStore.swift`, `Summarizer.swift` (passes every minute, `claude -p`), `Support.swift` (paths, log, AX helpers).
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

After a recorder change, check by hand: switch apps and tabs, open a Chrome incognito and a Safari private window and confirm nothing from them lands in `events/`, send a Slack message and check the submit event, then wait for the next 10-minute summary in the log.
