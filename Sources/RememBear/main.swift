import AppKit

// `remembear search …` from a shell (the app's binary, linked into
// ~/.local/bin by restart.sh). Anything else runs the menu bar app.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "search" {
    exit(SearchCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

// Anything else from a shell (or an agent) says how to search. Only macOS
// (Finder, Spotlight, login) starts the menu bar app: its parent is launchd.
// A bare `remembear` from a shell used to become a second copy of the app.
if CommandLine.arguments.count > 1 || getppid() != 1 {
    print("To search what was on screen: remembear search <words> [--limit N] [--days N] [--json]")
    print("RememBear itself runs from ~/Applications/RememBear.app.")
    exit(CommandLine.arguments.count > 1 ? 2 : 0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
