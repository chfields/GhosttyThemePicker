# Security Policy

## About This App

Ghostty Theme Picker is a simple, open-source macOS menu bar app. The entire codebase is available for inspection in this repository.

### What This App Does

- Runs `ghostty +list-themes` to get available themes
- Runs `ghostty --theme=<name>` to launch Ghostty with a theme
- Stores recent theme names in UserDefaults (local preferences)

### What This App Does NOT Do

- No network requests (except what Ghostty itself may do)
- No data collection or telemetry
- No file system access beyond launching Ghostty
- No background processes after you quit it

## Code Scanning

This repository uses [GitHub CodeQL](https://codeql.github.com/) to automatically scan for security vulnerabilities. You can view the results in the Security tab.

## Why Is It Unsigned?

The app is not signed with an Apple Developer certificate because:
1. Apple Developer Program costs $99/year
2. This is a free, hobby project

You can verify the app is safe by:
1. Reading the source code (it's ~150 lines of Swift)
2. Building it yourself from source
3. Checking the CodeQL scan results

## Reporting a Vulnerability

If you discover a security issue, please open a GitHub issue or contact the maintainer directly.
