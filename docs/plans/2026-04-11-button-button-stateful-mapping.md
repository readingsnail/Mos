# Button-Button Stateful Mapping Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add true `down/up` stateful execution for the existing mouse-button action category while keeping every other predefined action on the current trigger path, and rename `MosInput*` to `Input*`.

**Architecture:** Rename the input model and processor layer, introduce an explicit action execution mode plus resolved-action representation, and let `InputProcessor` own all stateful session pairing for both custom-key output and the new mouse-button output path. Keep non-mouse predefined actions trigger-only, and centralize fail-safe release so disabled taps or teardown cannot leave synthetic outputs stuck.

**Tech Stack:** Swift, AppKit, CoreGraphics `CGEvent`, existing `ButtonCore`, `ShortcutExecutor`, and macOS unit tests via `xcodebuild test`

---

### Task 1: Rename `MosInput*` to `Input*`

**Files:**
- Modify: `Mos/InputEvent/MosInputEvent.swift`
- Modify: `Mos/InputEvent/MosInputProcessor.swift`
- Modify: `Mos/ButtonCore/ButtonCore.swift`
- Modify: `Mos/LogitechHID/LogitechDeviceSession.swift`
- Modify: `Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift`
- Modify: `Mos/Keys/KeyRecorder.swift`
- Modify: `MosTests/MosInputProcessorTests.swift`

**Step 1: Write the failing rename first**

Rename the primary types:

```swift
enum InputPhase { case down, up }
enum InputSource { case cgEvent(CGEvent), hidPlusPlus }
struct InputDevice: Codable, Equatable { ... }
struct InputEvent { ... }
enum InputResult: Equatable { case consumed, passthrough }
final class InputProcessor { ... }
```

Update references so the project no longer refers to `MosInputEvent`, `MosInputPhase`, `MosInputSource`, `MosInputDevice`, `MosInputResult`, or `MosInputProcessor`.

**Step 2: Run a focused test/build to verify it fails before all references are updated**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MosInputProcessorTests
```

Expected: compile failure while references still point to the old names.

**Step 3: Complete the rename**

Update all call sites and rename the test file content to match the new types. Keep behavior identical at this stage.

**Step 4: Run the focused test again**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MosInputProcessorTests
```

Expected: the existing processor tests pass again under the new names.

**Step 5: Commit**

```bash
git add Mos/InputEvent Mos/ButtonCore/ButtonCore.swift Mos/LogitechHID/LogitechDeviceSession.swift Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift Mos/Keys/KeyRecorder.swift MosTests/MosInputProcessorTests.swift
git commit -m "refactor(input): rename MosInput types to Input"
```

### Task 2: Add explicit execution-mode metadata to action definitions

**Files:**
- Modify: `Mos/Shortcut/SystemShortcut.swift`

**Step 1: Extend the action definition model**

Add an execution mode to `SystemShortcut.Shortcut`:

```swift
enum ActionExecutionMode {
    case trigger
    case stateful
}

struct Shortcut {
    let identifier: String
    let code: CGKeyCode
    let modifiers: NSEvent.ModifierFlags
    let executionMode: ActionExecutionMode
    ...
}
```

Default all existing shortcuts to `.trigger`.

**Step 2: Mark the mouse-button category as stateful**

Update:

```swift
static let mouseLeftClick = Shortcut("mouseLeftClick", 0xFFFF, [], executionMode: .stateful)
static let mouseRightClick = Shortcut("mouseRightClick", 0xFFFF, NSEvent.ModifierFlags(rawValue: 1), executionMode: .stateful)
static let mouseMiddleClick = Shortcut("mouseMiddleClick", 0xFFFF, NSEvent.ModifierFlags(rawValue: 2), executionMode: .stateful)
static let mouseBackClick = Shortcut("mouseBackClick", 0xFFFF, NSEvent.ModifierFlags(rawValue: 3), executionMode: .stateful)
static let mouseForwardClick = Shortcut("mouseForwardClick", 0xFFFF, NSEvent.ModifierFlags(rawValue: 4), executionMode: .stateful)
```

Leave every other predefined action at `.trigger`.

**Step 3: Run a build**

Run:

```bash
xcodebuild build -project Mos.xcodeproj -scheme Debug -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds with no behavior changes yet.

**Step 4: Commit**

```bash
git add Mos/Shortcut/SystemShortcut.swift
git commit -m "feat(shortcuts): add trigger and stateful execution modes"
```

### Task 3: Introduce resolved actions and stateful active sessions in `InputProcessor`

**Files:**
- Modify: `Mos/InputEvent/InputProcessor.swift`
- Modify: `Mos/Shortcut/ShortcutExecutor.swift`
- Modify: `Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift`
- Modify: `MosTests/MosInputProcessorTests.swift`

**Step 1: Add a resolved action representation**

Define a compact action model:

```swift
enum MouseButtonActionKind {
    case left
    case right
    case middle
    case back
    case forward
}

enum ResolvedAction {
    case customKey(code: UInt16, modifiers: UInt64)
    case mouseButton(kind: MouseButtonActionKind)
    case systemShortcut(identifier: String)
    case logiAction(identifier: String)

    var executionMode: ActionExecutionMode { ... }
}
```

Add a resolver that maps:

- cached `custom::` bindings -> `.customKey(...)`
- mouse-button category identifiers -> `.mouseButton(...)`
- `logi...` identifiers -> `.logiAction(...)`
- everything else -> `.systemShortcut(...)`

**Step 2: Replace raw active bindings with active sessions**

Change the processor state from:

```swift
private var activeBindings: [TriggerKey: ButtonBinding]
```

to:

```swift
private struct ActiveBindingSession {
    let triggerKey: TriggerKey
    let bindingId: UUID
    let action: ResolvedAction
}

private var activeBindings: [TriggerKey: ActiveBindingSession]
```

**Step 3: Update `process(_:)` semantics**

Implement:

```swift
if event.phase == .up {
    if let session = activeBindings.removeValue(forKey: key) {
        ShortcutExecutor.shared.execute(action: session.action, phase: .up)
        recomputeActiveModifierFlags()
        return .consumed
    }
    return .passthrough
}

for binding in bindings where binding.isEnabled {
    if binding.triggerEvent.matchesInput(event),
       let action = resolveAction(for: binding) {
        if action.executionMode == .trigger {
            ShortcutExecutor.shared.execute(action: action, phase: .down, binding: binding)
            return .consumed
        }

        activeBindings[key] = ActiveBindingSession(triggerKey: key, bindingId: binding.id, action: action)
        ShortcutExecutor.shared.execute(action: action, phase: .down, binding: binding)
        recomputeActiveModifierFlags()
        return .consumed
    }
}
```

Do not reparse the binding on `up`.

**Step 4: Add and update tests**

Add focused tests asserting:

- trigger actions do not create an active session
- stateful mouse-button actions consume both `down` and paired `up`
- `up` without prior `down` still passthroughs
- modifier injection still only derives from custom modifier actions

**Step 5: Run the tests**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MosInputProcessorTests
```

Expected: the processor tests pass with the new stateful session model.

**Step 6: Commit**

```bash
git add Mos/InputEvent/InputProcessor.swift Mos/Shortcut/ShortcutExecutor.swift Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift MosTests/MosInputProcessorTests.swift
git commit -m "feat(input): share stateful session flow across custom and mouse actions"
```

### Task 4: Make mouse-button actions phase-aware in `ShortcutExecutor`

**Files:**
- Modify: `Mos/Shortcut/ShortcutExecutor.swift`
- Modify: `MosTests/MosInputProcessorTests.swift`

**Step 1: Replace one-shot click helpers with phase-aware mouse-button execution**

Add a dedicated helper:

```swift
private func executeMouseButton(_ kind: MouseButtonActionKind, phase: InputPhase) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    let location = NSEvent.mouseLocation
    let screenHeight = NSScreen.main?.frame.height ?? 0
    let point = CGPoint(x: location.x, y: screenHeight - location.y)

    let spec = mouseEventSpec(for: kind, phase: phase)
    guard let event = CGEvent(mouseEventSource: source, mouseType: spec.type, mouseCursorPosition: point, mouseButton: spec.button) else { return }
    if let buttonNumber = spec.buttonNumber {
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
    }
    event.setIntegerValueField(.eventSourceUserData, value: MosEventMarker.syntheticCustom)
    event.post(tap: .cghidEventTap)
}
```

Then route resolved mouse-button actions through it:

```swift
func execute(action: ResolvedAction, phase: InputPhase, binding: ButtonBinding? = nil) {
    switch action {
    case .customKey(let code, let modifiers):
        executeCustom(code: code, modifiers: modifiers, phase: phase)
    case .mouseButton(let kind):
        executeMouseButton(kind, phase: phase)
    case .logiAction(let identifier):
        guard phase == .down else { return }
        executeLogiAction(identifier)
    case .systemShortcut(let identifier):
        guard phase == .down else { return }
        execute(named: identifier)
    }
}
```

Keep non-mouse actions trigger-only by ignoring `up`.

**Step 2: Run focused tests/build**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MosInputProcessorTests
xcodebuild build -project Mos.xcodeproj -scheme Debug -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass and build succeeds.

**Step 3: Commit**

```bash
git add Mos/Shortcut/ShortcutExecutor.swift MosTests/MosInputProcessorTests.swift
git commit -m "feat(shortcuts): execute mouse button actions with explicit down and up"
```

### Task 5: Centralize fail-safe release for all active stateful output

**Files:**
- Modify: `Mos/InputEvent/InputProcessor.swift`
- Modify: `Mos/ButtonCore/ButtonCore.swift`
- Modify: `Mos/LogitechHID/LogitechDeviceSession.swift`

**Step 1: Upgrade the clear path from "drop state" to "release then clear"**

Implement:

```swift
func clearActiveBindings() {
    for (_, session) in activeBindings {
        if session.action.executionMode == .stateful {
            ShortcutExecutor.shared.execute(action: session.action, phase: .up)
        }
    }
    activeBindings.removeAll()
    activeModifierFlags = 0
}
```

Avoid any recursion or re-entry assumptions in this release path.

**Step 2: Ensure every teardown path calls it**

Verify and update:

- tap disabled by timeout
- tap disabled by user input
- `ButtonCore.disable()`
- any processor reset paths used by HID++ integration

**Step 3: Run verification**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MosInputProcessorTests
xcodebuild build -project Mos.xcodeproj -scheme Debug -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Expected: no regressions, and the release path remains safe to call repeatedly.

**Step 4: Commit**

```bash
git add Mos/InputEvent/InputProcessor.swift Mos/ButtonCore/ButtonCore.swift Mos/LogitechHID/LogitechDeviceSession.swift
git commit -m "fix(input): release active stateful outputs during teardown"
```

### Task 6: Final verification and manual validation

**Files:**
- Review only

**Step 1: Run the full relevant test set**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MosInputProcessorTests -only-testing:MosTests/ButtonBindingTests
```

Expected: all relevant tests pass.

**Step 2: Run a final build**

Run:

```bash
xcodebuild build -project Mos.xcodeproj -scheme Debug -configuration Debug CODE_SIGNING_ALLOWED=NO
```

Expected: app builds successfully.

**Step 3: Manual runtime validation**

Validate:

- side button -> left mouse button posts `down` on press and `up` on release
- side button -> right mouse button behaves the same way
- side button -> Mission Control still triggers once on press only
- side button -> custom modifier still supports held virtual modifier injection
- disabling the button subsystem while a stateful button is held does not leave the synthetic output stuck

**Step 4: Review diff**

Run:

```bash
git diff -- Mos/InputEvent Mos/ButtonCore/ButtonCore.swift Mos/LogitechHID/LogitechDeviceSession.swift Mos/Shortcut/SystemShortcut.swift Mos/Shortcut/ShortcutExecutor.swift Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift MosTests/MosInputProcessorTests.swift docs/plans/2026-04-11-button-button-stateful-mapping-design.md docs/plans/2026-04-11-button-button-stateful-mapping.md
```

Confirm that:

- only the mouse-button action category changed to stateful semantics
- all non-mouse predefined actions remain trigger-only
- `custom::` remains encoded the same way
- the new active session model is shared, not duplicated
