# Recall It

My own version of ChatGPT's Computer History, which I've turned off. It's a little menu bar app that keeps track of what I'm doing on my Mac, and every 10 minutes it asks Claude (on my own subscription) to write a short summary. Every 6 hours it writes a longer one covering the whole stretch. The summaries are Markdown files in the same format Codex used, so Agent Archive backs them up and my agents can search them ("what was I doing on Tuesday afternoon?").

Part of Mikerosoft, so yes, the name is a dig at Microsoft Recall.

## What it records

Through the macOS Accessibility API, while I'm at the Mac:

- the app and window in front, its title and (in browsers) the URL
- the words visible in that window when it changes, and once a minute after that if they change
- what I click on (the button or link name, not the screen)
- Return in a text field, with what the field held (a sent message, a search)
- keyboard shortcuts like ⌘T

It takes no screenshots and records no audio, and it doesn't log keystrokes. It stops when I'm away for 5 minutes or the screen is locked.

## What it never records

- **Private browser windows.** Chrome, Helium and other Chromium incognito windows, Safari Private Browsing, Firefox private windows and Edge InPrivate are spotted from the window title and skipped completely. A browser window whose title can't be read is skipped as well.
- **Password managers** (1Password, Passwords, Keychain Access, Bitwarden and friends), and the lock screen.
- **Secure text fields**, and fields labelled like passwords, codes or API keys. Anything that looks like a key, token or card number in window text gets masked.
- **Apps and sites I've excluded** from the menu ("Don't Record Slack", "Don't Record bank.com"). Excluding a site covers its subdomains.

All of those checks happen before anything is written, so excluded stuff never reaches the disk.

## Where things go

- `~/Library/Application Support/Recall It/events/`: raw events, one file per 10 minutes, **deleted after 48 hours**.
- `~/Library/Application Support/Recall It/summaries/`: the summaries, kept. Agent Archive reads this folder.
- `~/Library/Logs/recall-it.log`: what it did and when, with no activity content.

Both folders are owner-only. The only thing that leaves the Mac is the 10-minute digest sent to Claude to be summarised, and the summaries Agent Archive backs up.

## Menu

Pause for an hour or until tomorrow, stop recording the app in front (or the site it's on), forget the last hour (which deletes events and summaries here, and Agent Archive mirrors recent deletes), open the summaries folder, and Open at Login.

## Settings

There's no settings window. Use `defaults write com.mikerosoft.recall-it <key> <value>`:

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

Then allow Recall It under System Settings › Privacy & Security › Accessibility. To hook it up to Agent Archive:

```bash
agent-archive configure-computer-history --dir "$HOME/Library/Application Support/Recall It/summaries"
```

`uninstall.sh` removes the app. Add `--delete-data` to delete the events and summaries too.
