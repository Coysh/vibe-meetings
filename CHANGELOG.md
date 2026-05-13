# Changelog

All notable changes to VibeMeetings are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioned with [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-05-13

### Added
- Dashboard homepage with greeting, today's schedule, recent meetings, and quick stats
- Sidebar search (title, attendees, org, transcript, and summary content)
- Sidebar "Recent" view with date-grouped sections (Today, Yesterday, This Week, Earlier)
- Upcoming calendar events in sidebar with Teams "Join & Record" buttons
- Meeting chat — global AI panel to ask questions across all meetings
- Configurable organizations in Settings (replaces hardcoded list)
- Import transcript from external tool for re-summarization
- Pre-meeting notifications 3 minutes before calendar events
- "Join & Record" notification action for Teams meetings
- Meeting app name shown in mic-active notification (e.g., "Microsoft Teams is using the microphone")
- Clickable meeting title in recording bar to navigate to live transcript
- Echo-reduced audio file (audio-cleaned.m4a) written in chunks for reliable AAC encoding
- Sparkle auto-update framework integration
- CHANGELOG.md with automatic release notes extraction in release.sh

### Fixed
- Mic-active notification no longer fires all day when Teams/browsers are running (requires active calendar event)
- Echo-reduced audio file was unplayable (AAC encoder buffer overflow)
- Removed Chrome, Safari, Slack from meeting app detection (browsers run all day)


## [1.2.0] - 2025-05-13

### Added
- Dashboard homepage replacing empty detail view
- Sidebar dual view modes (Folders / Recent)
- Sidebar search across meeting titles, transcript, and summary content
- Date-grouped recent meetings (Today, Yesterday, This Week, Earlier)
- Upcoming calendar events in sidebar
- Import transcript feature for older meetings
- Pre-meeting macOS notifications (3 min before)
- Teams "Join & Record" action in notifications
- Meeting app detection in mic-active banner
- Clickable recording bar title for live transcript navigation
- Post-recording metadata sheet
- Auto-end detection (silence, calendar end, app exit)
- Dock badge during recording
- Auto-summary generation after recording stops

### Fixed
- Echo-reduced audio producing unplayable M4A files
- Notification spam from always-running apps (calendar event gate)

## [1.1.0] - 2025-05-12

### Added
- Dock recording badge
- Post-recording sheet with metadata editing
- Auto-end detection for meetings (silence threshold, calendar end time, app monitoring)
- Auto-summary generation after recording stops
- WhisperKit model picker with download buttons in Settings
- Model loading before transcription starts (with progress indicator)

### Fixed
- WhisperKit model name and stale-directory download check
- WhisperKit variant name used as local model directory name
- FSEvents flags for folder watcher

## [1.0.0] - 2025-05-10

### Added
- Live dual-channel recording (mic + system audio)
- Real-time transcription via WhisperKit (on-device)
- Stereo M4A recording with echo reduction post-processing
- Meeting summarization via Ollama (local) or OpenAI
- Calendar integration with Teams meeting detection
- Recurring meeting folder routing (series ID, person, org)
- Editable folder tree sidebar with drag-and-drop
- Meeting metadata: type (1:1/group), org, attendees, labels
- Configurable Ollama endpoint with LAN support
- Custom summarization prompt support
- Microphone device selection in Settings
- Resume recording for existing meetings

[Unreleased]: https://github.com/Coysh/vibe-meetings/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/Coysh/vibe-meetings/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Coysh/vibe-meetings/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Coysh/vibe-meetings/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Coysh/vibe-meetings/releases/tag/v1.0.0
