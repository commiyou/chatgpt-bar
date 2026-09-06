# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.3] - 2026-09-06

### Changed

- Enlarged the application mark to better match the ChatGPT icon proportions.
- Synchronized the menubar icon with the interwoven application mark.

## [0.1.2] - 2026-09-06

### Changed

- Replaced the application icon with a white-background, black interwoven
  ChatGPT-style mark and regenerated the macOS icon bundle.

## [0.1.1] - 2026-09-05

### Fixed

- Prevented duplicate panel shortcut dispatch from toggling Pin on and off within one physical key press.

### Changed

- Prepared GitHub packaging, CI, tagged release automation, and documentation.
- Copy Last Response now defaults to rendered assistant DOM Markdown, with an
  opt-in ChatGPT native Copy strategy that triggers the page button and observes
  the native pasteboard without intercepting clipboard APIs.

## [0.1.0] - 2026-09-05

### Added

- Menu bar ChatGPT shell with `WKWebView`.
- Global show / hide shortcut and panel-local shortcuts.
- Pin support, URL Scheme commands, macOS Services, configurable selectors, diagnostics, and settings persistence.
