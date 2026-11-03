# Security policy

## Reporting a vulnerability

Please report security problems privately. Do not open a public issue.

Use GitHub Security Advisories: open the repository's **Security** tab and choose **Report a vulnerability**. Include the Desks version, your macOS version, what you did and what happened. A small proof of concept helps.

I will answer as soon as I can, usually within a few days. Desks is a small free project maintained in spare time, so please be patient.

## Supported versions

Only the latest release gets fixes.

## What is in scope

- Ways for another app or user to make Desks do something they should not be able to do (for example the `desks://` URL scheme running a destructive action without the user's consent).
- Reading or writing files outside `~/Library/Application Support/Desks`, Desks preferences and the paths in the signing scripts.
- Problems in the build, signing and release scripts or workflows (for example leaking a password, or running unsafe input).
- Crashes or hangs that an outside app can trigger.

## What is out of scope

- Windows that stay parked in a screen corner after a crash. This is a known limit; use "Bring all windows back" (⌃⌥⇧R).
- The fact that builds are not notarized. This is stated in the README.
- Problems that need the attacker to already control your account or have Accessibility access.
- Bugs in macOS or in other apps.

## Privacy

Desks has no network code and no telemetry. If you find any outgoing connection, please report it.
