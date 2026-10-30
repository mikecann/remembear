# RememBear

My own version of ChatGPT's Computer History, which I've turned off. It's a little menu bar app that keeps track of what I'm doing on my Mac, and every 10 minutes it asks Claude (on my own subscription) to write a short summary. Every 6 hours it writes a longer one covering the whole stretch. The summaries are Markdown files in the same format Codex used, so Agent Archive backs them up and my agents can search them ("what was I doing on Tuesday afternoon?").

Part of Mikerosoft, and one of its bears with BrowserBear and ComputerCub. It was called Recall It until 30 Oct 2026.

## What it records

While I'm at the Mac:

- the app and window in front, its title and (in Chrome and other Chromium browsers) the URL
- the words in that window when it changes, once a minute after that if they change, and just after I press Return. The words come from a screenshot of that one window, read by macOS's own text recognition on the Mac. The screenshot is never saved or sent anywhere: it's dropped as soon as it's read
- that I pressed Return (a sent message, a search), and keyboard shortcuts like ⌘T

It records no audio and doesn't log keystrokes. It stops when I'm away for 5 minutes or the screen is locked.

Until 30 Oct 2026 it read windows through the Accessibility API instead, and asked what was under every click. That made every app it read do the work itself: Threadbear took half a second to switch views, and Chrome and Electron apps had to keep their accessibility trees built. A screenshot comes from the window server and costs the app nothing.

## What it never records

- **Private browser windows.** The window list only has a page's title, and an incognito window's title doesn't say it's incognito, so RememBear asks Chrome (and other Chromium browsers) over AppleScript whether the front window is normal or incognito, and records nothing unless it's normal. Safari and Firefox can't say, so nothing from them is recorded at all.
- **Password managers** (1Password, Passwords, Keychain Access, Bitwarden, KeePassXC, Proton Pass and friends), macOS's own password and Touch ID prompts, and the lock screen.
- **Secrets on screen.** A screenshot sees everything, so the text is masked before it's written: every environment variable's value (`FOO_BAR=…`, `FOO_BAR: …`, a dashboard's name and value), anything labelled as a password, token or key, passwords in URLs, auth headers, Convex deploy keys, private keys, long base64 lines, and anything shaped like an API key, token or card number.
- **Pages that make or show keys.** Any page whose address looks like it's for API keys, tokens, credentials, secrets or environment variables (OpenAI's /api-keys, GitHub's /settings/tokens, a Convex dashboard's settings and so on), and any screen whose text reads like a new key being shown ("copy it now, you won't be able to see it again"), is skipped whole, as a new key can be any shape. That covers an agent making a key for me with BrowserBear or ComputerCub too.
- **Apps and sites I've excluded** from the menu ("Don't Record Slack", "Don't Record bank.com"). Excluding a site covers its subdomains.

Those checks happen before a window is captured, and again after, so excluded stuff never reaches the disk.

## Where things go

- `~/Library/Application Support/RememBear/events/`: raw events, one file per 10 minutes, **deleted after 48 hours**.
- `~/Library/Application Support/RememBear/summaries/`: the summaries, kept. Agent Archive reads this folder.
- `~/Library/Logs/remembear.log`: what it did and when, with no activity content.

Both folders are owner-only. The only thing that leaves the Mac is the 10-minute digest sent to Claude to be summarised, and the summaries Agent Archive backs up.

## Menu

Pause for an hour or until tomorrow, stop recording the app in front (or the site it's on), forget the last hour (which deletes events and summaries here, and Agent Archive mirrors recent deletes), open the summaries folder, and Open at Login.

## Settings

There's no settings window. Use `defaults write app.mikecann.remembear <key> <value>`:

| Key | Default | |
|---|---|---|
| `tenMinuteModel` | `haiku` | model for the 10-minute summaries |
| `sixHourModel` | `sonnet` | model for the 6-hour ones |
| `claudePath` | `~/.local/bin/claude` | |
| `claudeConfigDir` | unset (`~/.claude`) | which Claude login to use |
| `excludedApps`, `excludedSites` | empty | also editable from the menu |

## Install

```bash
bash restart.sh
```

The first time it opens, a setup window lists the permissions it needs (Screen Recording, Accessibility, and controlling Chrome), each with a red circle that turns green once it's on and a button that opens the right part of System Settings. It's under Permissions… in the menu later, or open RememBear.app again. To hook it up to Agent Archive:

```bash
agent-archive configure-computer-history --dir "$HOME/Library/Application Support/RememBear/summaries"
```

`uninstall.sh` removes the app. Add `--delete-data` to delete the events and summaries too.
