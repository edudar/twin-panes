import AppKit

// No storyboard or nib: the app builds its menu and windows in code.
let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()
