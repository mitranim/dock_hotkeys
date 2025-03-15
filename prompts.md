Our app provides global hotkeys to activate apps by their Dock positions. Currently it uses AppleScript. We're going to drop AppleScript, and use exclusively native MacOS APIs from Swift.

The app code is in `./src/main.swift`.

## Step 1: cleanup

Drop all code related to AppleScript: `compiledScripts`, `compileScriptForPosition`, and so on. Keep `activateDockApp`, with a placeholder comment.

In `hotkeyMappings`, decrement each position by 1: from 1 to 0, from 2 to 1, and so on.

## Step 2: Dock plist

Add a static variable holding the FS path to the Dock plist file.

Add a small function that:
- Reads the Dock preferences plist
- Maps `persistent-apps` to their `bundle-identifier`s
- Uses `NSWorkspace.shared.urlForApplication` to map those bundle identifiers to URLs
- Returns a data structure mapping the ordinal positions of persistent apps (0-indexed) to those URLs

Add a static variable holding the resulting data structure.

Add a small function that uses native APIs to watch the Dock plist file. On changes, reparse the plist and update the variable that holds the mapping. Start watching after registering the event tap.

## Step 3: opening apps

In `registerWithEventTap`, when a hotkey is found, use the resulting position to lookup the app URL in the data structure obtained from the plist file. If the URL is found (not nil), dispatch `activateDockApp` with that URL.

In `activateDockApp`: take an app URL, and use `NSWorkspace.shared.openApplication` to launch the app.

## Step 4: review

Review the changes and the resulting code. Consider if anything needs to be fixed (missing error handling, wrong APIs, etc.).

---

We forgot about Finder.

- In `loadDockAppURLs`, use index 0 for app with bundle identifier `com.apple.Finder`.
- For other persistent apps, increase each index by 1 in the mapping.

---

<!-- In `src/main.swift`, we watch the Dock plist file for changes. When the target file is modified (either by the Dock itself, for example when reordering items, or via `touch` from a shell), our callback doesn't seem to be invoked. Nothing is printed, and our app does not refresh `dockAppURLs`. We'd like to fix that.

---

The previous change causes us to detect a change just once, and prematurely. Further changes are not detected.

---

Adding a timer did allow us to detect changes. However, now the app constantly uses CPU in the background due to this polling. This is not an option. We want to avoid repeated actions, polling, any kind of busywaiting. Consider all possible ways of detecting plist changes without relying on timers, with native FS APIs. -->

---

Rewrite `loadDockAppURLs` to get Dock preferences from `CFPreferencesCopyMultiple` (an AppKit API) instead of reading the plist file. Be concise but correct.

Instead of watching the plist file (which is unreliable, we don't get notified), watch its parent directory (only `.write` events). On FS events, detect if the plist file got changed. It would be ideal to detect that in-memory without FS access. Be concise but correct.

---

`hasDockPlistChanged` and `updateDockPlistModificationDate` are invoked one after another, and both access the FS attributes of the file, resulting in a redundant FS operation. Deduplicate into one FS operation. Be concise but correct.