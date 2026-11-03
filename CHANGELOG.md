# Changelog

All notable changes to Desks are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Desks no longer takes focus away from system prompts (Touch ID, password sheets) or dialogs. After a window closes, Desks now moves focus only when it landed in a hidden window. Before, a closing popup (such as Chrome's autofill list) made Desks focus the last window again, which cancelled the Touch ID prompt.

## [0.2.0] - 2026-11-03

### Added
- Rules per app: send windows of an app to a layout, make them sticky, or ignore them. A rule needs an app (bundle id) and can add a title pattern (regular expression). New rules start disabled. "Apply Now" runs the rules on open windows.
- Apps to open with a layout: each layout can list apps. When you switch to the layout, apps that are not running are opened in the background, and their first new window joins the layout.
- Saved arrangements: save the window places of a layout and restore them later. Available in the bar's right-click menu, in Settings, with the URL scheme and the CLI. There is an option to restore the arrangement when you switch.
- `desks://` URL scheme and the `desks` command line tool (`scripts/desks`, installed with `scripts/install-cli.sh`).
- Appearance settings: bar size, labels (number and app icons, or number only), opacity, lock bar position, reset bar position.
- Draggable bar with its own position per display, and a handle on top of the bar.
- Move window to layout shortcuts (⌃⌥⇧ and a digit) and number pad digits for the digit shortcuts.
- Animated bar: sliding highlight, chip transitions, fades. Respects Reduce Motion.
- A hover delete button on bar chips.
- Offscreen render mode for UI review (`Desks --render-settings <dir>`) and `scripts/screenshots.sh`.
- Release workflow, CI, contributing and security documents, issue templates, MIT license.

### Changed
- Layout numbers are compact and 1-based. Switching to a layout that does not exist does nothing. Empty layouts you have not renamed are removed when you leave them.
- Rules save their title pattern when you press Return or leave the field. Invalid patterns show a warning.
- The `rescue` URL asks for confirmation. `?display=` is accepted only by the commands that use it.
- App icons in the bar follow the most recently used windows of each layout.

### Fixed
- A launch crash caused by bar updates inside SwiftUI layout passes.
- Focus jumping back after a switch, and windows that did not unpark on the first try.

## [0.1.0] - 2026-11-03

First version.

### Added
- Layouts per display. Each display has its own list. Switching parks the windows of other layouts in a screen corner and restores the target ones, with no animation.
- Per-window membership, so the same app can have windows in two layouts.
- New windows join the current layout.
- Sticky windows that are shown in every layout of their display.
- Move overlay and a pill bar with a "+" button.
- Delete a layout: its windows go to the first layout.
- Layouts and membership survive relaunch and reboot. A crash journal restores parked windows on the next launch.
- Rescue shortcut and menu item that bring all windows back, and Pause.
- Cmd-Tab into a parked window switches to its layout. After a window closes, focus goes to the last used window of the layout.
- Handling of full screen, dialogs, native tabs, sleep and wake, and display changes.
- Menu bar menu, Settings window with rebindable shortcuts (KeyboardShortcuts), launch at login.
- Self-signed build scripts that keep the Accessibility permission across rebuilds.

[Unreleased]: https://github.com/shanto462/desks/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/shanto462/desks/releases/tag/v0.2.0
[0.1.0]: https://github.com/shanto462/desks/releases/tag/v0.1.0
