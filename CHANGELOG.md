# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Support pasting multi-line text blocks into the TUI prompt, with bracketed-paste detection so a pasted block is never mistaken for a typed Enter (#34)
- Add a log file for the detached Athanor daemon (#13)
- Add a `/clear` TUI command that resets a session's conversation context in place, without restarting the daemon or spawning a new session (#31)

### Fixed
- TUI is silent when wedged: no activity indicator, no daemon connectivity, discarded command failures (#24)

### Changed
- Document chainlink's single-session-per-database model and its multi-agent workarounds (#32)
