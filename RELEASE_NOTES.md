# Whisperino 3.0.0 — The VoiceOS Rebuild

This is Whisperino’s biggest update yet: a complete rebuild of the notch experience, a much more reliable recording pipeline, multilingual dictation controls, screen-aware tools, and an entirely redesigned settings app.

## A new dynamic notch

- Rebuilt the overlay as one continuous top-edge surface with proper outward-curved shoulders and smooth state morphing.
- Added a compact idle target: hover for a liquid-glass glow and haptic feedback, then click to start dictating.
- Added a responsive left-to-right voice meter driven by real microphone input.
- Added stable recording controls, including an explicit cancel button and a microphone source selector.
- Added polished listening, processing, result, error, and tool states without controls jumping during transitions.
- Result cards now use a perimeter lifetime timer that remains visible over light, dark, and colorful windows.

## Works across displays

- Added a virtual top-edge island for external displays that do not have a physical notch.
- Whisperino follows the active external display and keeps the same hover, click, recording, and result behavior there.
- Improved placement around crowded menu bars and the macOS microphone-in-use indicator.

## Better audio and microphone handling

- Whisperino can pause active media when dictation starts and resume only the playback it paused when recording ends or is cancelled.
- Reworked CoreAudio startup so a slow, disconnected, or changing input device cannot freeze the app.
- Microphone choices are persisted by stable device ID and can be switched from the notch.
- If no real sound is detected, Whisperino surfaces the microphone selector automatically.
- Improved quiet-speech sensitivity while keeping the meter smooth and preventing four permanently maxed-out bars.
- Fixed microphone selector rows and recording controls moving sideways during open/close animations.

## Multilingual dictation

- Added a custom searchable multi-select language control.
- Selecting one language locks recognition to it for predictable results.
- Selecting several languages keeps automatic switching enabled and primes recognition toward that preferred set.
- Language preferences are snapshotted per recording, including long recordings split into multiple chunks.

## Safer screen-aware actions

- Added a typed assistant runtime with explicit session and tool lifecycles.
- Added local Finder search and file-result cards.
- Added calendar event previews with confirmation before saving.
- Added web-search previews with confirmation before opening a browser.
- Screen context may help resolve phrases such as “this person,” but screenshots never authorize an action.
- Unknown tools, unexpected arguments, stale confirmations, and unapproved side effects are rejected by the host app.

## A completely redesigned settings app

- Settings now opens directly to General instead of hiding Settings inside an overview screen.
- Reorganized navigation into Overview, General, Dictation, AI, Dictionary, Snippets, and Agents.
- Added clear App, Preferences, and Personalize groups in the sidebar.
- Replaced native-looking switches, selectors, fields, and shortcut pickers with one custom Whisperino design system.
- Moved languages, recording shortcuts, and auto-submit behavior into a dedicated Dictation page.

## Fixes and polish

- Fixed the fallback transcript briefly appearing before text was pasted into a selected text field.
- Improved result-card copy behavior and automatic dismissal.
- Added deterministic visual QA modes for notch states, external displays, microphone input, and light-background timer contrast.
- Added runtime tests for typed assistant-tool validation and confirmation requirements.

## Upgrade note

macOS may ask you to re-enable **Accessibility** after updating because the app’s code signature changes between builds. Open **System Settings → Privacy & Security → Accessibility**, enable Whisperino, then quit and reopen it once. Screen Recording is requested only when you first use Talk to your screen; Calendar access is requested only after you approve saving an event.
