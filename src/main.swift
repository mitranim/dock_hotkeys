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
    // Control+backtick (key code 50) for position 1.
    Hotkey(keyCode: 50, modifiers: .maskControl): 1,

    // Control+1 through Control+0 for the rest.
    Hotkey(keyCode: 18, modifiers: .maskControl): 2,  // Control+1 -> position 2
    Hotkey(keyCode: 19, modifiers: .maskControl): 3,  // Control+2 -> position 3
    Hotkey(keyCode: 20, modifiers: .maskControl): 4,  // Control+3 -> position 4
    Hotkey(keyCode: 21, modifiers: .maskControl): 5,  // Control+4 -> position 5
    Hotkey(keyCode: 23, modifiers: .maskControl): 6,  // Control+5 -> position 6
    Hotkey(keyCode: 22, modifiers: .maskControl): 7,  // Control+6 -> position 7
    Hotkey(keyCode: 26, modifiers: .maskControl): 8,  // Control+7 -> position 8
    Hotkey(keyCode: 28, modifiers: .maskControl): 9,  // Control+8 -> position 9
    Hotkey(keyCode: 25, modifiers: .maskControl): 10, // Control+9 -> position 10
    Hotkey(keyCode: 29, modifiers: .maskControl): 11, // Control+0 -> position 11
  ]

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  // Track permission status to avoid unnecessary re-registration
  private var permissionsGranted = false
  private var hotkeysRegistered = false

  // Observers for app activation
  private var workspaceObserver: NSObjectProtocol?

  // Cache of compiled AppleScripts for each Dock position
  private var compiledScripts: [Int: NSAppleScript] = [:]

  init(verbose: Bool = false) {
    self.verbose = verbose
  }

  deinit {
    unregisterHotkeys()
    if let observer = workspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
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

  private func compileScriptForPosition(_ position: Int) -> NSAppleScript? {
    let script = """
    tell application "System Events"
      -- Get dock app name.
      tell process "Dock"
        set dockAppName to name of UI element \(position) of list 1
      end tell

      -- Get frontmost app display name instead of process name.
      set frontProcess to first process whose frontmost is true
      set frontAppName to displayed name of frontProcess

      if dockAppName is equal to frontAppName then
        return "App at position \(position) is already active, ignoring hotkey"
      end if

      -- Activate the app.
      tell process "Dock"
        set frontmost to true
        click UI element \(position) of list 1
      end tell
      return "Activated dock app: " & dockAppName
    end tell
    """

    return NSAppleScript(source: script)
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

          if let position = manager.hotkeyMappings[hotkey] {
            // Dispatch to main thread to avoid blocking event tap
            DispatchQueue.main.async {
              manager.activateDockApp(at: position)
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

    // Clear the script cache
    compiledScripts.removeAll()

    // Reset registered flag to allow re-registration
    hotkeysRegistered = false
  }

  private func activateDockApp(at position: Int) {
    log("Activating Dock item at position \(position)")

    var error: NSDictionary?
    let scriptObject: NSAppleScript

    // Get cached script or compile a new one
    if let compiledScript = compiledScripts[position] {
      scriptObject = compiledScript
    } else if let newScript = compileScriptForPosition(position) {
      scriptObject = newScript
      // Cache the script for future use
      compiledScripts[position] = scriptObject
    } else {
      return
    }

    // Execute the script
    let result = scriptObject.executeAndReturnError(&error)
    if let error = error {
      log("AppleScript error: \(error)")
    } else if let resultString = result.stringValue {
      log(resultString)
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
