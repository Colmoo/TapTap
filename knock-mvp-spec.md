# Tap-to-Shortcut macOS App MVP Spec

## Goal
Build a personal macOS utility that lets a user trigger actions by physically tapping the Mac or the trackpad. The MVP should focus on one reliable loop: detect tap pattern -> classify gesture -> map to action -> execute action.[cite:18][cite:21][cite:27]

## Product Definition
The product is a lightweight background app for macOS that listens for simple tap gestures and converts them into user-defined automations such as running Apple Shortcuts, launching apps, executing shell commands, or controlling media.[cite:2][cite:21]

## Core User Story
- As a Mac user, the app should let me assign single, double, and triple taps to actions so I can trigger workflows without remembering keyboard shortcuts.[cite:2][cite:18]
- As a user on unsupported hardware, I should still be able to use trackpad-based tapping as the primary input mode.[cite:18][cite:21]

## MVP Scope

### In Scope
- Background macOS app, preferably menu bar first.[cite:21][cite:27]
- Tap gesture detection for 3 gestures: single, double, triple.[cite:2]
- Trackpad tap detection as the first implementation path.[cite:18]
- Action binding UI for each gesture.[cite:21]
- Action execution for:
  - Apple Shortcuts.[cite:2][cite:21]
  - Shell commands/scripts.[cite:2]
  - Launching apps.[cite:21]
  - Basic media controls like play/pause/next.[cite:21]
- Permissions onboarding for Accessibility and Automations if required by execution strategy.[cite:18]
- Start at login option.[cite:21]

### Out of Scope
- iPhone companion app.[cite:21]
- Per-app profiles and context-aware mappings.[cite:2]
- Cloud sync, analytics, user accounts, and collaboration.
- Fancy onboarding animations or polished marketing site.
- Chassis vibration detection on day 1 unless trackpad detection proves insufficient.[cite:27]

## Functional Requirements

### Input Layer
- Detect three gesture classes: single tap, double tap, triple tap.[cite:2]
- Provide a configurable debounce/timing window so adjacent taps can be grouped into one gesture.
- Ignore accidental touch noise as much as possible, because trust depends on low false positives.[cite:21][cite:27]
- Log incoming tap events in a debug panel for tuning.

### Mapping Layer
- Each gesture maps to exactly one action in the MVP.
- Supported action types:
  - Run Apple Shortcut by name.[cite:2][cite:21]
  - Run shell command.[cite:2]
  - Open application bundle.
  - Send media command.[cite:21]
- Persist bindings locally in a lightweight config file.

### Execution Layer
- Execute actions asynchronously so gesture detection stays responsive.
- Show success/failure in a minimal activity log.
- Prevent accidental rapid-fire execution with a short cooldown per gesture.

### UI Layer
- Menu bar item opens settings window.
- Settings sections:
  - Detection.
  - Gesture bindings.
  - Permissions.
  - Debug log.
- Include a “Test detection” mode that shows recognized gesture labels in real time.

## Suggested Technical Architecture

### App Structure
- `TapInputService`: receives raw tap/touch events.
- `GestureClassifier`: groups raw events into single/double/triple taps.
- `BindingStore`: stores gesture -> action mapping.
- `ActionExecutor`: runs the bound action.
- `PermissionManager`: checks/request required macOS permissions.
- `SettingsViewModel`: exposes config to SwiftUI UI.
- `EventLogger`: stores recent detections and execution results.

### Event Pipeline
1. Listen for raw input events.
2. Convert raw events into timestamped tap candidates.
3. Apply thresholding/debounce window.
4. Classify into single/double/triple.
5. Resolve bound action.
6. Execute action.
7. Log outcome.

## Recommended Stack
- Language: Swift.
- UI: SwiftUI.
- App style: menu bar utility using `MenuBarExtra` or an AppKit bridge if needed.
- Local persistence: `UserDefaults` for first version, JSON file if configuration grows.
- Shortcut execution: call the macOS `shortcuts` CLI or equivalent automation path supported by the system.[cite:2]
- Shell command execution: `Process`.
- App launching: `NSWorkspace.shared.openApplication` or equivalent.
- Media control: system media command integration through supported macOS APIs or scripted fallbacks.

## Hard Part: Input Detection
The biggest implementation risk is not the settings UI; it is reliable tap detection. Public descriptions of the existing app emphasize trackpad tap gestures on any Mac and hardware-based tapping on supported devices, which suggests the MVP should start from the most controllable input source first: trackpad gestures.[cite:18][cite:21][cite:27]

### Practical MVP Recommendation
- Start with a keyboard-modified trackpad tap or gesture detector if raw physical tap sensing is hard to access reliably.[cite:18]
- Treat “true chassis knock detection” as a later version.
- Build the rest of the product so the input source is abstracted behind `TapInputService`.

## Data Model

```ts
GestureType = 'single' | 'double' | 'triple'

ActionType = 'shortcut' | 'shell' | 'app' | 'media'

Binding = {
  gesture: GestureType,
  actionType: ActionType,
  value: string,
  enabled: boolean
}
```

## Settings to Expose
- Double-tap max interval in milliseconds.
- Triple-tap max interval in milliseconds.
- Global cooldown in milliseconds.
- Sensitivity/threshold if using custom signal detection.
- Launch at login.
- Enable debug logging.

## UX Notes
- The app should feel invisible until needed; menu bar utility is the right mental model.[cite:21][cite:27]
- Setup should take less than 2 minutes: choose gesture, choose action, test, done.[cite:21]
- A live recognition label like “Detected: Double Tap” is important for trust.
- Use conservative defaults to minimize accidental triggers.

## Milestones

### Milestone 1: Skeleton App
- Create menu bar app.
- Build settings window.
- Add local config persistence.
- Add debug log panel.

### Milestone 2: Gesture Engine
- Implement raw event listener.
- Add debounce/grouping logic.
- Recognize single/double/triple taps.
- Show recognized gestures in UI.

### Milestone 3: Action Execution
- Add shortcut runner.[cite:2][cite:21]
- Add shell command runner.[cite:2]
- Add app launcher.[cite:21]
- Add media control action.[cite:21]

### Milestone 4: Stability
- Add cooldowns.
- Add false-positive filtering.
- Add startup launch option.[cite:21]
- Improve permission handling.[cite:18]

## Acceptance Criteria
- Single, double, and triple tap are recognized consistently in test mode.
- Each gesture can be bound to one action.
- Bound actions run successfully from the background app.[cite:2][cite:21]
- The app remains responsive while actions execute.
- False triggers are low enough that the app can stay enabled during normal use.

## Nice-to-Have After MVP
- Per-app gesture profiles.[cite:2]
- Chassis knock detection on supported hardware.[cite:27]
- iPhone companion sensor mode.[cite:21]
- Import/export bindings.
- More action types such as URL open, AppleScript, and window management.

## First Build Plan for Claude Code
1. Scaffold a SwiftUI macOS menu bar app.
2. Implement `Binding`, `GestureType`, `ActionType`, and persistence.
3. Create settings UI with 3 gesture rows.
4. Add debug event stream UI.
5. Implement a placeholder gesture simulator button for development.
6. Implement real input detection behind `TapInputService`.
7. Wire `ActionExecutor` for shortcuts, shell commands, app open, and media.
8. Add launch-at-login and permission checks.
9. Test on real hardware and tune debounce thresholds.

## Prompt to Continue in Claude Code
Use this project brief to scaffold a SwiftUI macOS menu bar utility named `TapTrigger`. Build the MVP only. Prioritize architecture and working gesture-to-action execution over visual polish. Keep the input layer abstract so trackpad tap detection can later be swapped with chassis knock detection or iPhone sensor input. Start by generating the app structure, models, settings UI, persistence, and stub services, then implement the action executors, and finally implement the gesture detection pipeline.
