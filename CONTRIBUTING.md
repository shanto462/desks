# Contributing to Desks

Thank you for helping. Desks is a small project. Small, focused pull requests are the easiest to review.

## Ground rules

- No telemetry, no network calls, no analytics. Desks never sends data anywhere. A change that adds any of this will not be merged.
- Only the Accessibility permission. Do not add other permissions (Screen Recording, Input Monitoring) without opening an issue first.
- Keep private API use small and documented. Today there are three: `_AXUIElementGetWindow`, `_SLPSSetFrontProcessWithOptions` and the public CGWindowList. If you add one, list it in `README.md` and `docs/BEHAVIOR.md`.
- Do not copy code from GPL projects. Desks is MIT. If you adapt MIT code, add it to `THIRD_PARTY_NOTICES.md`.
- Never put real personal data in code, tests, screenshots or issues: no real names, emails, window titles or display names. Use sample values.

## Build and run

You need macOS 13 or newer and Xcode (or the command line tools) with Swift 5.9 or newer.

```sh
swift build                        # debug build
scripts/make-signing-identity.sh   # once per Mac, keeps the Accessibility permission
scripts/build-app.sh               # release build to build/Desks.app
```

The signing script creates its own keychain (`desks-dev.keychain-db`) and never touches your login keychain. Without it the build is signed ad-hoc and macOS asks for the Accessibility permission again after each build.

## UI changes: use render mode

Render mode draws the Settings pages, the bar and the move overlay with sample data into PNG files. It never starts the engine, moves no windows and asks for no permission.

```sh
swift build -c release --product Desks
.build/release/Desks --render-settings /tmp/desks-render
```

Look at the PNGs in light and dark mode before you open a pull request. If the UI changed, run `scripts/screenshots.sh` and include the updated `docs/images`.

## Code style

- Swift 5.9, 4 spaces, see `.editorconfig`. Follow the style of the file you edit.
- The window engine (`Sources/DesksCore`) has no UI code. The UI (`Sources/Desks`) talks to the engine through the contract in `Sources/DesksCore/Contract.swift`.
- Accessibility calls can be slow or fail. Keep them off the main thread and use timeouts like the existing code does.
- Shell scripts must pass `shellcheck`. CI runs it.
- Write clear comments for why, not what. Use simple English.

## Tests

Desks does not have unit tests, by choice: nearly all of its behavior is real windows and real apps, which a mock cannot show. Instead, CI checks that the app builds, signs and passes lint, and you test by hand. Run the checklist below for the part you changed.

Manual checklist:

- [ ] Build checks: `swift build` and `scripts/build-app.sh` succeed with no warnings. `codesign --verify --deep --strict build/Desks.app` passes.
- [ ] Accessibility stays granted after a rebuild (with the "Desks Dev" identity).
- [ ] Switch layouts with ⌃⌥1 and ⌃⌥2: the window sets swap quickly and no sliver stays on a neighbour display.
- [ ] A new window joins the current layout. "+" opens an empty layout.
- [ ] ⌃⌥M moves a window. ⌃⌥S makes it sticky and it shows in every layout.
- [ ] Deleting a layout moves its windows to the first layout. The first layout cannot be deleted.
- [ ] Two windows of one app can be in two layouts.
- [ ] Quit and relaunch, then reboot: membership and window places return.
- [ ] `kill -9` Desks and relaunch: all parked windows come back.
- [ ] Cmd-Tab to a parked window switches to its layout. Closing a window does not switch layouts.
- [ ] Native full screen, a save dialog, a Terminal tab, Zoom, Chrome and an Electron app behave.
- [ ] Sleep and wake, and unplug and plug a display.
- [ ] Rebind a shortcut and check the conflict warning. Settings opens from the menu and from ⌃⌥,.
- [ ] Rules, apps to open and arrangements, if you touched them.
- [ ] `desks help` and a few `DESKS_DRY_RUN=1 desks ...` calls, if you touched the CLI.

## Pull requests

1. Open an issue first for big changes, so we can agree on the idea.
2. Keep one topic per pull request.
3. Fill in the pull request template. Say how you tested.
4. Update `CHANGELOG.md` (Unreleased section) and `docs/BEHAVIOR.md` when behavior changes.

## Releases (maintainers)

1. Move the Unreleased notes to a new version section in `CHANGELOG.md`.
2. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the same version.
3. Push a tag `vX.Y.Z`. The release workflow builds `Desks-X.Y.Z.zip` and creates the GitHub Release. It fails if the tag and the plist version differ.

Builds are signed ad-hoc and are not notarized.
