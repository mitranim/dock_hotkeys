import Cocoa
import Foundation
import Carbon

struct Hotkey: Hashable {
  let keyCode: Int
  let modifiers: CGEventFlags

  func hash(into hasher: inout Hasher) {
    hasher.combine(keyCode)
    hasher.combine(modifiers.rawValue)
  }
}

class HotKeyManager {
  // Whether to enable verbose logging
  private let verbose: Bool

  let hotkeyMappings: [Hotkey: Int] = [
    // Control+backtick (key code 50) for position 0 (always Finder).
    Hotkey(keyCode: 50, modifiers: .maskControl): 0,

    // Control+1 through Control+0 for the rest.
    Hotkey(keyCode: 18, modifiers: .maskControl): 1,  // Control+1 -> position 1
    Hotkey(keyCode: 19, modifiers: .maskControl): 2,  // Control+2 -> position 2
    Hotkey(keyCode: 20, modifiers: .maskControl): 3,  // Control+3 -> position 3
    Hotkey(keyCode: 21, modifiers: .maskControl): 4,  // Control+4 -> position 4
    Hotkey(keyCode: 23, modifiers: .maskControl): 5,  // Control+5 -> position 5
    Hotkey(keyCode: 22, modifiers: .maskControl): 6,  // Control+6 -> position 6
    Hotkey(keyCode: 26, modifiers: .maskControl): 7,  // Control+7 -> position 7
    Hotkey(keyCode: 28, modifiers: .maskControl): 8,  // Control+8 -> position 8
    Hotkey(keyCode: 25, modifiers: .maskControl): 9,  // Control+9 -> position 9
    Hotkey(keyCode: 29, modifiers: .maskControl): 10, // Control+0 -> position 10
  ]

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  // Track permission status to avoid unnecessary re-registration
  private var permissionsGranted = false
  private var hotkeysRegistered = false

  // Observers for app activation
  private var workspaceObserver: NSObjectProtocol?

  // File system watcher for Dock plist changes
  private var dockPlistSource: DispatchSourceFileSystemObject?

  // Path to the Dock plist file and its parent directory
  private static let prefsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
  private static let dockPlistURL = prefsDirectoryURL.appendingPathComponent("com.apple.dock.plist")
  private var lastDockPlistModified: Date = Date(timeIntervalSince1970: 0)

  // Mapping of Dock positions to app URLs
  private var dockAppURLs: [Int: URL] = [:]

  init(verbose: Bool = false) {
    self.verbose = verbose
    self.dockAppURLs = loadDockAppURLs()
  }

  deinit {
    unregisterHotkeys()
    if let observer = workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    stopWatchingDockPlist()
  }

  // Logging method that respects verbose setting
  private func log(_ message: String) {
    if verbose {
      print(message)
    }
  }

  func requestAccessibilityPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true] as CFDictionary
    permissionsGranted = AXIsProcessTrustedWithOptions(options)
    return permissionsGranted
  }

  func setupPermissionMonitoring() {
    // Only set up if permissions aren't granted yet.
    if !permissionsGranted {
      log("Setting up permission change monitoring")

      // Set up distributed notification for TCC database changes.
      let distributedCenter = DistributedNotificationCenter.default()

      // Add multiple observers to catch different possible notifications.
      distributedCenter.addObserver(
        forName: NSNotification.Name("com.apple.accessibility.api"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.checkAndUpdatePermissions()
      }

      // Also monitor app activation as backup.
      workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.checkAndUpdatePermissions()
      }
    }
  }

  func checkAndUpdatePermissions() {
    if !permissionsGranted && AXIsProcessTrusted() {
      log("Detected accessibility permission change!")

      // First, completely unregister existing hotkeys and clean up resources
      unregisterHotkeys()

      // Mark as granted but reset registration flag to force recreation
      permissionsGranted = true
      hotkeysRegistered = false

      // Register hotkeys from scratch to create new resources
      registerHotkeys()

      log("Successfully initialized hotkeys after permission change")
    }
  }

  func registerHotkeys() {
    // Avoid re-registering if already done
    if hotkeysRegistered {
      return
    }

    // Check accessibility permissions first.
    let currentPermissions = AXIsProcessTrusted()
    permissionsGranted = currentPermissions

    if !currentPermissions {
      print("Warning: Accessibility permissions not granted. Hotkeys may not work.")
      print("Please enable in System Settings → Privacy & Security → Accessibility.")
      // Continue registration attempt, but it likely won't work without permissions
    }

    if registerWithEventTap() {
      log("Successfully registered hotkeys using CGEventTap")
      hotkeysRegistered = true
    }
  }

  private func loadDockAppURLs() -> [Int: URL] {
    let keys = ["persistent-apps"] as CFArray
    let dockPrefs = CFPreferencesCopyMultiple(keys, "com.apple.dock" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

    guard let preferences = dockPrefs as? [String: Any],
          let persistentApps = preferences["persistent-apps"] as? [[String: Any]] else {
      print("Error loading Dock preferences")
      return [:]
    }

    var appURLs: [Int: URL] = [:]

    // Add Finder at position 0 (it's always the first item in the Dock)
    if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Finder") {
      appURLs[0] = finderURL
    }

    // Map persistent apps, adding 1 to index to account for Finder being at position 0
    for (index, app) in persistentApps.enumerated() {
      if let tileData = app["tile-data"] as? [String: Any],
         let bundleIdentifier = tileData["bundle-identifier"] as? String,
         let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        // Add 1 to index: position 0 is Finder, persistent apps start at position 1
        appURLs[index + 1] = appURL
      }
    }

    return appURLs
  }

  private func registerWithEventTap() -> Bool {
    // Create an event tap to monitor key combinations.
    let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

    guard let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: eventMask,
      callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
        if type == .keyDown {
          let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon!).takeUnretainedValue()
          let modifiers = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
          let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
          let hotkey = Hotkey(keyCode: Int(keyCode), modifiers: modifiers)

          if let position = manager.hotkeyMappings[hotkey],
             let appURL = manager.dockAppURLs[position] {
            // Dispatch to main thread to avoid blocking event tap
            DispatchQueue.main.async {
              manager.activateDockApp(appURL: appURL)
            }

            // Consume the event
            return nil
          }
        }

        // Pass through all other events.
        return Unmanaged.passRetained(event)
      },
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    ) else {
      print("Failed to create event tap")
      return false
    }

    // Create a run loop source and add it to the current run loop.
    self.eventTap = tap
    self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    startWatchingDockPlist()
    return true
  }

  func unregisterHotkeys() {
    log("Unregistering previous hotkeys...")

    // Clean up event tap
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFMachPortInvalidate(tap)
      eventTap = nil
    }

    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
      runLoopSource = nil
    }

    // Stop file watching if active
    stopWatchingDockPlist()

    // Reset registered flag to allow re-registration
    hotkeysRegistered = false
  }

  private func activateDockApp(appURL: URL) {
    log("Activating app at \(appURL.path)")

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true

    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
      if let error = error {
        print("Error opening application: \(error)")
      }
    }
  }

  private func startWatchingDockPlist() {
    stopWatchingDockPlist()

    let directoryPath = HotKeyManager.prefsDirectoryURL.path

    // Open a file descriptor for the preferences directory We have to watch the
    // directory instead of the file itself, because for this file, we don't
    // reliably get notifications about changes.
    let fileDescriptor = open(directoryPath, O_EVTONLY)
    if fileDescriptor < 0 {
      print("Error: Unable to open preferences directory for monitoring")
      return
    }

    log("Watching \(directoryPath) for changes")

    // Store initial modification date
    _ = checkAndUpdateDockPlist()

    // Create a dispatch source to monitor the directory
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: .write,
      queue: DispatchQueue.main
    )

    // Set the event handler
    source.setEventHandler { [weak self] in
      guard let self = self else { return }

      // Check if Dock plist has been modified
      if let hasChanged = self.checkAndUpdateDockPlist(), hasChanged {
        self.log("Dock preferences changed, updating app URLs")
        self.dockAppURLs = self.loadDockAppURLs()
      }
    }

    // Set cancellation handler to close the file descriptor
    source.setCancelHandler {
      close(fileDescriptor)
    }

    // Store the source and start monitoring
    dockPlistSource = source
    source.resume()
  }

  private func checkAndUpdateDockPlist() -> Bool? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: HotKeyManager.dockPlistURL.path),
          let modDate = attributes[.modificationDate] as? Date else {
      return nil
    }
    let hasChanged = modDate > lastDockPlistModified
    lastDockPlistModified = modDate
    return hasChanged
  }

  private func stopWatchingDockPlist() {
    if let source = dockPlistSource {
      source.cancel()
      dockPlistSource = nil
    }
  }

  func stop() {
    unregisterHotkeys()
    CFRunLoopStop(CFRunLoopGetCurrent())
  }
}

// Convert key code to human-readable string
func keyCodeToString(keyCode: Int) -> String {
  // Create a CGEvent to simulate a key press
  if let source = CGEventSource(stateID: .hidSystemState) {
    if let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true) {
      if let nsEvent = NSEvent(cgEvent: keyDownEvent) {
        if let char = nsEvent.charactersIgnoringModifiers, !char.isEmpty {
          return char
        }
      }
    }
  }
  // Fallback if event creation fails
  return "[\(keyCode)]"
}

@main
struct DockHotkeysApp {
  static func main() {
    // Parse command line arguments
    let arguments = CommandLine.arguments
    let verbose = arguments.contains("-v")

    // Create manager instance
    let hotKeyManager = HotKeyManager(verbose: verbose)

    if verbose {
      print("dock_hotkeys CLI")
      print("Available hotkeys:")

      // Dynamically generate hotkey list from manager's mappings, sorted by Dock position
      let sortedHotkeys = hotKeyManager.hotkeyMappings.sorted { $0.value < $1.value }
      for (hotkey, position) in sortedHotkeys {
        let keyName = keyCodeToString(keyCode: hotkey.keyCode)

        // Build modifier string in standard order: Alt, Cmd, Ctrl, Shift
        var modifiers = ""
        if hotkey.modifiers.contains(.maskAlternate) { modifiers += "Alt+" }
        if hotkey.modifiers.contains(.maskCommand) { modifiers += "Cmd+" }
        if hotkey.modifiers.contains(.maskControl) { modifiers += "Ctrl+" }
        if hotkey.modifiers.contains(.maskShift) { modifiers += "Shift+" }
        print("  \(modifiers)\(keyName) -> Dock position \(position)")
      }

      print("Press Ctrl+C to quit")
    } else {
      print("dock_hotkeys running. Use -v for verbose output. Press Ctrl+C to quit.")
    }

    // Request accessibility permissions if needed.
    let trusted = hotKeyManager.requestAccessibilityPermissions()

    if trusted {
      if verbose {
        print("Accessibility permissions granted")
      }
    } else {
      print("Please grant accessibility permissions when prompted")
      print("(You may need to manually enable in System Settings → Privacy & Security → Accessibility)")
      if verbose {
        print("You can continue granting permissions while the app is running")
      }

      // Set up comprehensive permission monitoring
      hotKeyManager.setupPermissionMonitoring()
    }

    // Register hotkeys - will be recreated when permissions change
    hotKeyManager.registerHotkeys()

    if verbose {
      print("dock_hotkeys is running. Hotkeys will activate the configured Dock positions.")
      print("If hotkeys don't work yet, grant permissions and they'll activate automatically.")
    }

    // Keep the program running.
    RunLoop.current.run()
  }
}
