// Tier 3, macOS side of keeping out of the way: hides every app of this Wine install as
// soon as it shows up (the test copy of the app and its games), so their windows stay
// out of sight and the app you're using keeps the keyboard. tests/wine/winctl.c also
// minimizes the windows inside Wine. Runs until killed.
// Usage: focusguard <path fragment of the Wine install>
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: focusguard <Wine install path fragment>\n".data(using: .utf8)!)
    exit(2)
}
let fragment = CommandLine.arguments[1]
setvbuf(stdout, nil, _IOLBF, 0)
while true {
    for app in NSWorkspace.shared.runningApplications
    where !app.isHidden && app.activationPolicy == .regular && app.executableURL?.path.contains(fragment) == true {
        // hide() asks; it returns before the app is hidden, so it can't tell us.
        _ = app.hide()
        print("hiding \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
    }
    // Lets NSWorkspace update its list of apps between checks.
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
}
