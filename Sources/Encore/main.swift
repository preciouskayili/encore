import AppKit

// Writing to the helper after it has quit must not take the whole app down.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Lives in the menu bar, not the Dock.
app.run()
