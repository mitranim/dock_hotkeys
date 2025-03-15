# Overview

A CLI MacOS utility that provides global hotkeys to activate apps in the Dock by their ordinal positions.

The code was mostly written via Anthropic's Claude Code.

## Features

* Press Control+backtick to activate app 0 in your Dock (Finder).
* Press Control+1-0 to activate the other apps in your Dock (from 1 to 10).
* Minimal and lightweight.
* No external dependencies.
* No AppleScript.
* CLI only.

## Requirements

* MacOS 12.0 or later.
* Swift. May require `xcode-select --install`.

## Installation

First, clone this repository via `git`, or download the zip. Navigate to its directory in a terminal.

You can try out the app without any installation. The OS will prompt you about [#permissions](#permissions), see instructions below.

```sh
make run
```

If you intend to run it manually as a `dock_hotkeys` command (from any directory), this command copies the executable to `~/.local/bin`, making it globally available:

```sh
make install
```

If you prefer it to auto-start and run in the background, this command adds the plist to `~/Library/LaunchAgents` and starts the agent:

```sh
make agent
```

Optionally run `make clean` to remove build cache (150 MB or so), which is unused after installation.

## Uninstallation

To remove both the executable and the agent plist, run `make uninstall`.

Then go to System Settings > Privacy & Security > Accessibility, and remove `dock_hotkeys` if it's present.

## Permissions

`dock_hotkeys` requires Accessibility permissions to function properly. When you first launch the app, you'll be prompted to grant these permissions.

If you're running the app from a terminal in the foreground, the OS may ask you to allow Terminal to control this computer. If you're running the app in the background via a launch agent, you'll need to grant permissions specifically to the app:

1. Go to System Settings > Privacy & Security > Accessibility.
2. Click the lock icon to make changes.
3. Add `dock_hotkeys` to the list of apps (if missing), and turn the switch on.

The OS may also open a dialog with something like:

> "dock_hotkeys" wants access to control "System Events.app"

If it does, click "Allow" or similar.

The new permissions should be detected within a few seconds.

If the app is running but does not appear to work after granting all permissions, restart it via `make agent.restart`.

## Usage

Once `dock_hotkeys` is running and you've granted it accessibility permissions:

* Press Control+backtick to activate the first app in your Dock (Finder).
* Press Control+1, Control+2 and so on until 0, to activate the other apps in your Dock.

If launched in the foreground from a terminal, the app will keep running until you quit it with Control+C.

## How it works

* Uses the `CGEventTap` API to monitor keyboard events and detect matching key combinations.
* When a match is detected, uses `NSWorkspace.shared.openApplication` to idempotently open/focus an app.
* Gets Dock app positions from Dock preferences accessed via `CFPreferencesCopyMultiple`.
* Detects changes by watching `~/Library/Preferences/com.apple.dock.plist`.
  * It would be ideal to use an in-memory notification API without having to watch files, but was unable to find a working API that would actually notify us about changes in app positions.

## TODO

Consider using the `RegisterEventHotKey` API to register specific hotkeys. In the `CGEventTap` API, the OS calls our callback for every keystroke. In `RegisterEventHotKey`, it might not.

## License

https://unlicense.org
