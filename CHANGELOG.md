# Changelog

All notable changes to VibeMeetings are documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioned with [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.9.0] - 2026-10-12
- The sidebar lists only your newest meetings (under Recent); the full lists are in All meetings, a folder, or Home. Multi-select with ⌘/⇧-click and press Delete to remove several
- **A much more accurate transcript.** Comparing transcripts of the same recordings, the live transcript was missing about 40–60% of what was said. Two changes fix most of that:
- The summary is written after the transcript has been improved, and from the live transcript if that fails. While it waits, the Summary tab says so, with "Write it now from the live transcript". Improving a past meeting's transcript by hand now rewrites its summary too
  - *Improve transcript after the recording.* When a recording ends, the saved audio is transcribed again with a larger model (large-v3 turbo, about 600 MB, downloaded on first use) and no time pressure, then speaker detection and the summary run on the better text. It runs in the background, never while you're recording, and shows its progress on the meeting. The live transcript is kept: ⋯ → Restore live transcript. Turn it off, or pick another model, in Settings → Engines → Transcript accuracy. **Improve transcript…** in a meeting's ⋯ menu does it on demand, and **Improve past meetings…** in Settings does it for everything you've already recorded
- Resume Recording is now a button at the bottom of a finished meeting (also in the ⋯ menu)
  - *A new live transcriber.* It used to re-read the last 30 seconds every 5 seconds and let each pass overwrite the one before, which clipped the first words of every window; windows that were mostly silence made Whisper write "[silence]" and skip the speech. It now keeps text once it has settled, starts each pass at a sentence boundary, never sends silence to the model, and brings quiet speech up to a level Whisper reads well. On two of your recordings (4-minute samples, compared with the offline pass) the other side of the call went from 105 to 252 of 265 words in one, and from 87 to 566 of 577 in the other, and it needs less than half the processing time of the old one
- Notification banners (meeting starting, call detected, meeting ended) are now cards
  - "[silence]", "[POP]" and "[END]" no longer end up inside transcript lines, and the last few seconds of a recording are no longer cut off when you press Stop

  - **Names and terms** (Settings → Engines → Transcript accuracy): if the transcript spells a name slightly differently from your list ("Teresa" for "Theresa"), it's corrected. Your organisations, and each meeting's attendees and title, are included automatically. (Giving Whisper the names up front was tried first: it made transcripts shorter and slower, and it breaks the turbo models, so it isn't used.)
### Fixed
  - Settings → Engines → Transcript accuracy also has the spoken language (English by default; "detect automatically" picks it once per recording rather than on every short window). Two command-line tools, `vm-transcribe-eval` and `vm-claude-check`, measure transcript accuracy and try the Claude engine
- "Couldn't improve the transcript (… avfaudio error 2003334207)" on a recording that was renamed or filed while it was being improved: the audio is now opened once, and the meeting's folder is looked up again whenever something is saved to it, template write-ups included
- **Individual speakers.** After a group meeting, the other side of the call is split into Speaker 1, Speaker 2 and so on, on this Mac, before the summary is written, so summaries can say who said what. Each speaker gets a colour in the transcript, and renaming one suggests the meeting's calendar attendees. 1:1s are left as they are, and **Detect speakers…** does it for a meeting you've already recorded. On by default; turn it off in Settings → Recording
- If another recording starts while a transcript is being improved, the meeting is written up from the live transcript straight away (and its summary updated once the improved one is ready), instead of waiting for the new recording to end
- **Claude Code as a summary and chat engine.** Choose "Claude Code" in Settings → Engines to write summaries and templates, and answer chat questions, with the `claude` command-line tool you already have, signed in with your Claude account (Vibe Meetings never sees a key). In chat, Claude can search and read your meeting files itself, so questions across many meetings ("what did we decide about the budget this quarter?") work properly; you see what it's searching and reading, and the meetings it used appear under "Based on". It's read-only and limited to your meetings folder: it can't change files, run commands or browse the web. Turn the file search off in Settings if you'd rather it only gets a few matched summaries. Transcripts are sent to Anthropic when this engine is on. Includes a `vm-claude-check` command-line tool for trying the engine
- **Floating indicator you can move and size.** Drag it from anywhere (not just the dot and timer), and it snaps to screen edges and corners. Three sizes: Compact (timer and Stop), Standard, and Expanded, a card with the live transcript and both level meters that you can resize by its corner. Right-click it to change size, reset its position or hide it; the size is also in Settings → Recording and the menu bar. Each size remembers its own position
- **Default templates.** Mark any template as a default (Templates page → ⋯ → Make Default, or in its editor) and it's written for every new recording, one after another once the summary is done, each as its own tab. Until then its tab says it's waiting
- **Edit the Summary prompt on the Templates page.** A "Summary" row at the top opens the full prompt, with a "Customised" tag if it differs from the built-in one, Show Default and Reset to Default. It's the same prompt as Settings → Prompts, so the two stay in step. A prompt you've customised doesn't pick up later improvements to the built-in one until you reset it
- **Recent meetings in the sidebar.** The eight newest meetings sit under Recent (collapsible), with the time, a red dot on the one being recorded, and the open one highlighted. "Show all" opens All meetings
- **Summary templates.** Add "+ Template" to any meeting to write it up another way — Customer: Discovery, Pipeline Review, Follow-up Email, 1:1, Standup and more — each as its own tab. Star your favourites, and create your own on the new Templates page (sidebar). Your main summary and its custom prompt are unchanged
- Folders can have an emoji icon (right-click → Set Icon…), and there's an Inbox for meetings that aren't filed in a folder
- On a meeting: participant avatars, a Share menu (copy the summary, transcript, or everything as Markdown; export to a file), and a dropdown on each speaker's name to rename them
- "Next up" pages through the next week of calendar events, with refresh and a "join link only" filter. A gear beside Start Recording / Resume Recording opens quick recording settings (microphone, echo, speaker detection, the floating indicator)
- Appearance setting (Settings → General): dark by default, or light, or follow the system. The app's accent is now violet whatever the system accent is
- A redesigned main window: a narrow sidebar (Home, All meetings, your folders), a date-grouped meeting list ("Today", "Yesterday", "16 June 2026") with search, and a meeting page with a back button, chips for its folder, date, duration and people, and underlined tabs. Recording controls float at the bottom of the window instead of a bar across the top


### Changed
### Added

## [1.8.0] - 2026-10-03
- Resuming a meeting no longer deletes its audio: the earlier audio is kept as a backup file, and you are asked first
### Added
- Confirmation before replacing a summary, importing over a transcript, deleting a transcript line, and clearing chat. A failed summary keeps the previous one
- **Speaker-echo cancellation.** If you take calls on speakers, your microphone hears the other people through the room and your side of the transcript came out garbled. Vibe Meetings now cancels that echo using the call audio as a reference (Settings → Recording → Speaker echo). It leaves headphones alone and never changes your saved recording
- Errors saving notes, transcript edits, renames, moves and deletes are now shown instead of silently ignored
- First-run setup that explains each permission before asking (microphone, system audio, transcription model download, calendar, notifications, summaries). Run it again from Settings → General
- Editing a meeting no longer silently assigns an organisation; the title can be edited
- Recording menu (Record / Stop with ⇧⌘R), New Folder (⇧⌘N), ⌘1–4 for the meeting tabs, ⌥⌘F to search meetings, ⌘G / ⇧⌘G to step through transcript matches, ⌥⌘I for chat, Space to play / pause audio
- Organise no longer permanently hides skipped meetings, and no longer creates a second "People" folder tree
- A Recording tab in Settings (microphone, echo, ending a recording, the floating indicator)
- Chat history is kept when the chat panel is re-opened or switched
- Rename "Others" to a real name for a meeting (right-click the speaker in the transcript)
- An in-progress calendar meeting no longer disappears from Upcoming
- Selecting a folder shows its meetings; playback speed control; Copy and Cancel for summaries; a Stop button for chat answers
- Sheets that could have no way to close, a crash when two participants shared an id, and a sidebar multi-selection that opened an arbitrary meeting

### Changed
- Echo in the transcript is caught far more reliably: it is matched across several lines of the other side, tolerates garbled words, and trims echoed words out of lines where you were also talking
- Recording now starts capturing audio immediately; the transcription model loads (or downloads, with progress) alongside instead of delaying the start
- "Keep in current location" now really keeps the meeting where it is. Choices are Automatic, Keep where it is, or a folder
- Dismissing "meeting may have ended" only quiets that one reason, for a while, instead of turning every end-of-meeting check off for the rest of the recording. The prompt also shows in the floating indicator and the menu
- Settings reorganised; calendar and notification settings explain how they depend on each other
- The app is called "Vibe Meetings" everywhere you see it

### Fixed
- Not capturing the other side of a call (system audio permission denied) is now shown clearly, with a button to fix it. It used to fail silently


- Failed recording starts stay on screen with Try again / Open Settings instead of disappearing after 15 seconds
- Changing the microphone during a recording now works with the main window closed


## [1.7.3] - 2026-10-01
- Settings → Calendar: checkboxes now update immediately when clicked, and long calendar lists are no longer cut off

### Changed
- The Settings window can be resized, and every tab scrolls
- Calendars are grouped by account, with All / None buttons and a filter box

### Fixed

## [1.7.2] - 2026-10-01
- 1.7.0 could freeze on launch (100% CPU) because of an endless update loop between the menu bar icon and its "Show in menu bar" setting

### Fixed

## [1.7.0] - 2026-10-01

- Escalating "you're in a call and not recording" reminders: immediately, again after 2 and 5 minutes, then every 5 minutes until you record, snooze or choose "Not a meeting". Only one reminder is ever shown in Notification Center. Toggle in Settings → Notifications
- **Record** on the call reminder starts recording instantly in the background, linked to the matching calendar event (or titled e.g. "Zoom call 14:05"). Also **Snooze 10 min** and **Not a meeting**; clicking the notification opens the start sheet
- Floating recording indicator: a small draggable pill on every Space (including over full-screen calls). It shows "Not recording · Record" during a call, and a timer with Stop while recording
- Menu bar icon with recording state, Record Now / Stop, Join & Record, Snooze and Not a meeting. Works with the main window closed
- "Starting now" notification for online meetings, and Join & Record for Zoom, Google Meet and Webex links as well as Teams
- Call detection for Slack, FaceTime, Discord, WhatsApp, Signal, Skype and browser-based calls (Google Meet, Teams on the web). Browser detection can be turned off
- "Meeting may have ended" notification with a Stop Recording button when the app window isn't in front. The meeting app releasing the microphone is now an end-of-meeting signal
- Settings warns when notifications are set to disappear after a few seconds ("Temporary"), with a button that opens the right System Settings pane. It also has a test call reminder
- New installs default to persistent (Alert-style) notifications

### Fixed
- Calls weren't detected after switching microphones (AirPods, a headset) while the app was running. Detection now covers every input device and identifies which app is using the microphone
- Notification buttons did nothing when the main window was closed, and were lost if the notification relaunched the app
- Pre-meeting reminders fired at the old time for moved events, and still fired for cancelled ones. They now follow calendar changes
- Call detection and calendar reminders only started once the main window had appeared

### Changed
- Closing the main window no longer stops call detection; the app keeps running in the menu bar / Dock
- The in-app "call detected" and calendar banners start recording immediately instead of opening the start sheet
- Meetings recorded from Zoom, Google Meet or Webex events store that platform. Versions 1.6.6 and earlier can't read these meetings, so update every Mac that shares the meetings folder
### Added

## [1.6.6] - 2026-08-17
- All-day calendar events are now ignored by call detection — they no longer shadow real meetings, trigger suggestion banners, or schedule pre-meeting reminders
- The "meeting detected" notification now stays in Notification Center for the duration of the call and is cleared automatically when recording starts, the call ends, or the suggestion is dismissed
- Dismissing the record suggestion now silences it for the rest of that call only — the next call gets a fresh banner and notification (previously a dismissal could suppress all future calls until a recording was made)
- The system notification is now posted even when the in-app suggestion banner is visible, so a hidden app window no longer means a missed reminder

### Changed

## [1.6.5] - 2026-07-16
### Added
- Notification when the microphone appears to be picking up no audio (muted, wrong input device, permission issue) during a recording, even while the rest of the call is still audible via system audio. Toggle in Settings → Auto-End Detection

### Changed
- Summary and action-item prompts now require a clear, single assignee per action item, defaulting to **You** (the meeting owner) instead of "Unassigned" when the transcript doesn't explicitly name someone



## [1.6.4] - 2026-07-03
### Fixed
- Echo suppression now catches *partial* echo — when the other party's voice bleeds in at low level and the mic transcribes it imperfectly (dropping words), `EchoDedup` previously kept the garbled "You" copy because a symmetric word-overlap score fell below threshold. It now scores directional containment (how much of the mic text is covered by the clean system channel), so degraded echo is removed while genuine speech spoken over the other party is preserved



## [1.6.1] - 2026-07-03

### Fixed
- Garbled, duplicated "You" transcript when not wearing headphones — the other party's voice bleeding from the speakers into the mic is now removed by cross-referencing the clean system-audio channel (`EchoDedup`)
- Whisper hallucinations and noise (e.g. `[silence]`, "Thanks for watching", "Please subscribe", degenerate word repetition) are now filtered consistently across the live view, the saved transcript, and the LLM export (`TranscriptNoiseFilter`)
- Resumed recordings no longer overlap or duplicate segments — new live segments are offset past the end of the loaded history

## [1.6.0] - 2026-07-02

### Added
- Crash failsafe: recordings now survive an unexpected crash, force-quit, or power loss
  - The transcript is checkpointed to disk every 10 seconds while recording, so at most a few seconds of speech can be lost
  - Audio is streamed to a crash-safe WAV sidecar in parallel with the compressed m4a; the WAV stays valid the moment each sample hits disk (unlike the m4a, which is only playable once the meeting ends cleanly)
  - On the next launch, any meeting whose recording was interrupted is automatically salvaged — its audio is repaired and made playable, an end time is stamped, and it is tagged `recovered`. Recovered audio appears in the meeting's Audio tab

### Changed
- Opening a past meeting now defaults to the **Summary** tab instead of Transcript (live, in-progress meetings still open on Transcript)

## [1.5.3] - 2026-07-02
### Fixed
- Crash (abort in `AVAssetWriter.finishWriting`) when ending a meeting where the audio writer never started or had already failed



## [1.5.0] - 2026-05-14

### Added
- Hot-swap microphone during active recording (Settings mic change applies immediately)
- Chat AI can query live transcript mid-meeting (not just saved meetings)
- CMD+F search in transcript view with match highlighting and count
- Home button in toolbar to return to dashboard
- "Organise Meetings" remembers previously triaged meetings (skip already-categorised)
- Chat panel: model picker, meeting scope filter, custom system prompt, Markdown rendering
- Impromptu call detection — notifications now fire when a meeting app + mic are active, even without a calendar event

### Fixed
- Meeting notifications not appearing for impromptu/ad-hoc calls (all detection paths previously required a calendar event)
- Mic banner no longer disappears during mute/unmute if a meeting app is still running
- Sparkle auto-update download URLs (pointed to 404 raw.githubusercontent.com instead of GitHub Release assets)

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

[Unreleased]: https://github.com/Coysh/vibe-meetings/compare/v1.9.0...HEAD
[1.9.0]: https://github.com/Coysh/vibe-meetings/compare/v1.8.0...v1.9.0
[1.8.0]: https://github.com/Coysh/vibe-meetings/compare/v1.7.3...v1.8.0
[1.7.3]: https://github.com/Coysh/vibe-meetings/compare/v1.7.0...v1.7.3
[1.7.2]: https://github.com/Coysh/vibe-meetings/compare/v1.6.6...v1.7.2
[1.7.0]: https://github.com/Coysh/vibe-meetings/compare/v1.6.5...v1.7.0
[1.6.6]: https://github.com/Coysh/vibe-meetings/compare/v1.6.4...v1.6.6
[1.6.5]: https://github.com/Coysh/vibe-meetings/compare/v1.5.3...v1.6.5
[1.6.4]: https://github.com/Coysh/vibe-meetings/compare/v1.5.0...v1.6.4
[1.5.3]: https://github.com/Coysh/vibe-meetings/compare/v1.3.0...v1.5.3
[1.5.0]: https://github.com/Coysh/vibe-meetings/compare/v1.3.0...v1.5.0
[1.3.0]: https://github.com/Coysh/vibe-meetings/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/Coysh/vibe-meetings/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Coysh/vibe-meetings/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Coysh/vibe-meetings/releases/tag/v1.0.0
