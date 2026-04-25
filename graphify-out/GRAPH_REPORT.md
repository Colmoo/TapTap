# Graph Report - .  (2026-04-19)

## Corpus Check
- Corpus is ~17,026 words - fits in a single context window. You may not need a graph.

## Summary
- 290 nodes · 441 edges · 20 communities detected
- Extraction: 83% EXTRACTED · 17% INFERRED · 0% AMBIGUOUS · INFERRED: 73 edges (avg confidence: 0.82)
- Token cost: 3,200 input · 2,800 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Core Services & Data Model|Core Services & Data Model]]
- [[_COMMUNITY_Swift Types & Protocols|Swift Types & Protocols]]
- [[_COMMUNITY_SwiftUI Views|SwiftUI Views]]
- [[_COMMUNITY_Calibration Manager|Calibration Manager]]
- [[_COMMUNITY_App Lifecycle & Wiring|App Lifecycle & Wiring]]
- [[_COMMUNITY_IMU & Hardware Input|IMU & Hardware Input]]
- [[_COMMUNITY_Gesture Classification|Gesture Classification]]
- [[_COMMUNITY_System Commands|System Commands]]
- [[_COMMUNITY_Action Error Handling|Action Error Handling]]
- [[_COMMUNITY_Binding Persistence|Binding Persistence]]
- [[_COMMUNITY_Event Logging|Event Logging]]
- [[_COMMUNITY_Permission Management|Permission Management]]
- [[_COMMUNITY_App Bundle Assembly|App Bundle Assembly]]
- [[_COMMUNITY_Menu Bar App|Menu Bar App]]
- [[_COMMUNITY_Key Tests|Key Tests]]
- [[_COMMUNITY_Service Tests|Service Tests]]
- [[_COMMUNITY_Package Config|Package Config]]
- [[_COMMUNITY_Media Tests|Media Tests]]
- [[_COMMUNITY_C Header|C Header]]
- [[_COMMUNITY_Settings ViewModel|Settings ViewModel]]

## God Nodes (most connected - your core abstractions)
1. `SystemCommand` - 27 edges
2. `GestureType` - 16 edges
3. `MediaCommand` - 13 edges
4. `ActionType` - 12 edges
5. `ActionExecutor` - 12 edges
6. `CalibrationManager` - 11 edges
7. `MicInputService` - 10 edges
8. `MicInputService` - 10 edges
9. `AppEnvironment` - 9 edges
10. `url` - 8 edges

## Surprising Connections (you probably didn't know these)
- `ActionExecutor` --semantically_similar_to--> `ActionExecutor (impl)`  [INFERRED] [semantically similar]
  knock-mvp-spec.md → CLAUDE.md
- `Trackpad Tap Detection` --semantically_similar_to--> `TapInputService (impl)`  [INFERRED] [semantically similar]
  knock-mvp-spec.md → CLAUDE.md
- `UserDefaults Persistence` --semantically_similar_to--> `BindingStore (impl)`  [INFERRED] [semantically similar]
  knock-mvp-spec.md → CLAUDE.md
- `TapInputService` --semantically_similar_to--> `TapInputService (impl)`  [INFERRED] [semantically similar]
  knock-mvp-spec.md → CLAUDE.md
- `GestureClassifier` --semantically_similar_to--> `GestureClassifier (impl)`  [INFERRED] [semantically similar]
  knock-mvp-spec.md → CLAUDE.md

## Hyperedges (group relationships)
- **Dual-Input Tap Detection Pipeline (IMU + Mic → GestureClassifier → ActionExecutor)** — claude_md_tap_accel_c, claude_md_micinputservice, claude_md_tapinputservice, claude_md_gestureclassifier, claude_md_actionexecutor [EXTRACTED 1.00]
- **Gesture Binding Data Model (GestureType + ActionType → Binding → BindingStore)** — knock_mvp_spec_gesturetype, knock_mvp_spec_actiontype, knock_mvp_spec_binding, knock_mvp_spec_bindingstore [EXTRACTED 1.00]
- **TDOA Side Classification (AVAudioEngine → highpass → noise floor → TDOA → TapSide)** — claude_md_avaudioengine, claude_md_highpass_filter, claude_md_noise_floor, claude_md_tdoa, claude_md_tapside [EXTRACTED 1.00]

## Communities

### Community 0 - "Core Services & Data Model"
Cohesion: 0.06
Nodes (43): ActionExecutor (impl), AppEnvironment, AppSettings, AVAudioEngine, BindingStore (impl), EventLogger (impl), GestureClassifier (impl), GestureType (count+side) (+35 more)

### Community 1 - "Swift Types & Protocols"
Cohesion: 0.07
Nodes (37): CaseIterable, Codable, LogEntry, Identifiable, ActionType, app, media, shell (+29 more)

### Community 2 - "SwiftUI Views"
Cohesion: 0.07
Nodes (22): App, BindingsView, GestureSlotButton, KeyboardMapView, MicUpsellBanner, TapDots, TapZoneColumn, CalibrationView (+14 more)

### Community 3 - "Calibration Manager"
Cohesion: 0.12
Nodes (9): CalibrationManager, CalibrationPhase, collectingDouble, collectingSingle, collectingTriple, complete, idle, Equatable (+1 more)

### Community 4 - "App Lifecycle & Wiring"
Cohesion: 0.18
Nodes (3): AppEnvironment, MicInputService, double

### Community 5 - "IMU & Hardware Input"
Cohesion: 0.15
Nodes (13): device_matching_cb(), dispatch_report(), gyro_device_matching_cb(), gyro_push_cb(), poll_timer_cb(), push_report_cb(), read_le32(), tap_accel_start() (+5 more)

### Community 6 - "Gesture Classification"
Cohesion: 0.12
Nodes (10): GestureClassifier, GestureClassifier, GestureType, double, single, triple, TapSide, center (+2 more)

### Community 7 - "System Commands"
Cohesion: 0.1
Nodes (20): SystemCommand, copy, doNotDisturb, emptyTrash, launchpad, lockScreen, missionControl, nextDesktop (+12 more)

### Community 8 - "Action Error Handling"
Cohesion: 0.22
Nodes (8): ActionError, emptyValue, notFound, processExited, unknown, ActionExecutor, LocalizedError, url

### Community 9 - "Binding Persistence"
Cohesion: 0.17
Nodes (2): BindingStore, BindingEditorSheet

### Community 10 - "Event Logging"
Cohesion: 0.25
Nodes (6): EventLogger, Kind, detection, error, execution, system

### Community 11 - "Permission Management"
Cohesion: 0.36
Nodes (1): PermissionManager

### Community 12 - "App Bundle Assembly"
Cohesion: 0.67
Nodes (3): build-app.sh, Info.plist, Rationale: SPM executable requires manual .app bundle assembly

### Community 13 - "Menu Bar App"
Cohesion: 1.0
Nodes (2): Menu Bar Utility Pattern, TapTrigger App

### Community 14 - "Key Tests"
Cohesion: 1.0
Nodes (0): 

### Community 15 - "Service Tests"
Cohesion: 1.0
Nodes (0): 

### Community 16 - "Package Config"
Cohesion: 1.0
Nodes (0): 

### Community 17 - "Media Tests"
Cohesion: 1.0
Nodes (0): 

### Community 18 - "C Header"
Cohesion: 1.0
Nodes (0): 

### Community 19 - "Settings ViewModel"
Cohesion: 1.0
Nodes (1): SettingsViewModel

## Knowledge Gaps
- **79 isolated node(s):** `center`, `left`, `right`, `single`, `double` (+74 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Menu Bar App`** (2 nodes): `Menu Bar Utility Pattern`, `TapTrigger App`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Key Tests`** (1 nodes): `test_keys.swift`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Service Tests`** (1 nodes): `test_smappservice.swift`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Package Config`** (1 nodes): `Package.swift`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Media Tests`** (1 nodes): `test_media.swift`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `C Header`** (1 nodes): `tap_accel.h`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Settings ViewModel`** (1 nodes): `SettingsViewModel`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `SystemCommand` connect `System Commands` to `Action Error Handling`, `Swift Types & Protocols`, `Binding Persistence`?**
  _High betweenness centrality (0.127) - this node is a cross-community bridge._
- **Why does `BindingEditorSheet` connect `Binding Persistence` to `Swift Types & Protocols`, `SwiftUI Views`?**
  _High betweenness centrality (0.120) - this node is a cross-community bridge._
- **Why does `CalibrationManager` connect `Calibration Manager` to `Gesture Classification`?**
  _High betweenness centrality (0.074) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `SystemCommand` (e.g. with `.loadFromStore()` and `.runSystemCommand()`) actually correct?**
  _`SystemCommand` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `MediaCommand` (e.g. with `.loadFromStore()` and `.sendMediaCommand()`) actually correct?**
  _`MediaCommand` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `center`, `left`, `right` to the rest of the system?**
  _79 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Core Services & Data Model` be split into smaller, more focused modules?**
  _Cohesion score 0.06 - nodes in this community are weakly interconnected._