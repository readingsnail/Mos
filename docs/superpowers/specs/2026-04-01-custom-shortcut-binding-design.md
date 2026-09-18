# Custom Shortcut Binding Design

## Overview

Allow users to record custom key combinations as button binding actions, complementing the existing predefined SystemShortcut list. Users can bind any key, modifier, or combination — enabling scenarios like binding a mouse side button to Shift for hold-to-modify workflows.

## Requirements

- Add "自定义…" menu item to the action popup in ButtonsView
- Reuse existing KeyRecorder/KeyPopover components for recording
- New `.adaptive` recording mode supporting: single keys, single modifiers, modifier combinations, and modifier+key combinations
- Timing-based intent detection (similar to single-click vs double-click on mobile)
- Mouse button down/up 1:1 maps to bound key down/up
- Zero performance impact on the event processing hot path
- macOS 10.13+ compatibility

## Design

### 1. Adaptive Recording Mode

#### New Mode

Add `.adaptive` to `KeyRecordingMode` enum. This mode is the superset of `.combination` and `.singleKey`, supporting all input types.

#### State Machine

```
IDLE
 │
 ├── Non-modifier key / Function key / Mouse / Logi
 │    → Record immediately → RECORDED
 │
 └── Modifier key(s) pressed → MODIFIER_HELD
      │
      ├── Another key pressed (modifier or regular)
      │    → Record as combination → RECORDED
      │
      ├── All modifiers released → MODIFIER_RELEASED_WAITING
      │    │
      │    ├── 300ms expires, no new input
      │    │    → Confirm single modifier(s) → RECORDED
      │    │
      │    └── New key pressed within 300ms
      │         → Cancel timer, return to appropriate state
      │
      └── 10s HOLD_CONFIRM_DELAY (held without release)
           → Confirm single modifier(s) → RECORDED (fallback)
```

#### Constants

- `ADAPTIVE_CONFIRM_DELAY = 0.3` (300ms) — post-release confirmation window
- `HOLD_CONFIRM_DELAY = 9.5` (9.5s) — fallback for indefinitely held modifiers (slightly less than global TIMEOUT to avoid race)

#### Behavior Matrix

| User Action | Result |
|---|---|
| Press `K` (non-modifier) | Immediately record `K` |
| Press `F5` (function key) | Immediately record `F5` |
| Hold `⌘` → press `K` | Record `⌘+K` |
| Hold `⌘+⇧` → press `K` | Record `⌘+⇧+K` |
| Press `⇧` → release → 300ms | Record `⇧` |
| Hold `⌘+⇧` → release all → 300ms | Record `⌘+⇧` |
| Press `⌘` → release → 150ms → press `⌘` → press `K` | Record `⌘+K` (timer cancelled) |
| Hold `⌘` for 10s without releasing | Record `⌘` (fallback) |
| Mouse side button | Immediately record |
| Logi HID++ button | Immediately record |
| Press ESC | Cancel recording |

#### Implementation

Add a `handleAdaptiveEvent()` method in `KeyRecorder`, branching from the existing `switch mode` flow. Existing `.combination` and `.singleKey` modes remain untouched.

Track adaptive state via a private enum:

```swift
private enum AdaptiveState {
    case idle
    case modifierHeld(modifiers: CGEventFlags)
    case modifierReleasedWaiting(modifiers: CGEventFlags)  // carries pending modifiers for 300ms timer
    case recorded
}
```

The `modifierReleasedWaiting` state carries the previously held modifiers so that:
- If a new modifier is pressed within 300ms, cancel timer and return to `modifierHeld` with combined modifiers
- If a non-modifier key is pressed within 300ms, record as combination (pending modifiers + key)
- If 300ms expires, confirm the pending modifiers as single-modifier recording

Two timers:
- `adaptiveConfirmTimer: Timer?` — 300ms post-release timer
- `holdConfirmTimer: Timer?` — 9.5s fallback timer (started on first modifier press, cancelled when non-modifier pressed or recording completes). Set to 9.5s (not 10s) to avoid race with the global `KeyRecorder.TIMEOUT` (10s)

### 2. Menu Integration & Popup Timing

#### Menu Structure

Add "自定义…" as the last item in the action popup menu, after all category submenus:

```
[Placeholder — current binding display]
─────────────
取消绑定
─────────────
⌨️  功能键           ▶
🖥  应用与窗口        ▶
📄  文档编辑          ▶
📁  访达操作          ▶
⚙️  系统功能          ▶
📸  截图             ▶
↔️  导航             ▶
🖱  鼠标按键          ▶
Logi  Logi 操作      ▶  (conditional)
─────────────
⌨️  自定义…
```

#### Implementation in ShortcutManager

Add the "自定义…" menu item in `ShortcutManager.buildShortcutMenu()`:
- Separator before it
- `representedObject = "__custom__"` (String marker)
- SF Symbol: `keyboard` (macOS 11.0+)
- Localized title via `NSLocalizedString`

#### Popup Timing (Critical)

Menu close and popover open must not overlap. Use `NSMenu.didEndTrackingNotification` for reliable sequencing:

```swift
// In ButtonTableCellView.shortcutSelected(_:)
@objc private func shortcutSelected(_ sender: NSMenuItem) {
    if sender.representedObject as? String == "__custom__" {
        let menu = sender.menu!
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: menu,
            queue: .main
        ) { [weak self] _ in
            NotificationCenter.default.removeObserver(observer!)
            guard let self = self, self.window != nil else { return }
            self.startCustomRecording()
        }
        return
    }
    // Normal shortcut handling...
}
```

**Why this approach:**
- Event-driven: fires only when menu fully closes
- One-shot: observer removed immediately after use
- Safe: `weak self` + `window != nil` guard prevents ghost popovers
- Scoped: bound to the specific menu instance

#### Recording Anchor

`startCustomRecording()` calls `KeyRecorder.startRecording(from: actionPopUpButton, mode: .adaptive)`, using the popup button itself as the popover anchor point.

#### Recording Completion

The cell receives the recorded event via a delegate/callback, converts it to a `custom::` binding string, and calls `onShortcutSelected` to update the ButtonBinding.

### 3. Data Model & Storage

#### Encoding Custom Bindings

Reuse `ButtonBinding.systemShortcutName` with a `custom::` prefix:

```
Format: "custom::<keyCode>:<modifierFlags>"

Examples:
  "custom::56:0"         → Left Shift alone (keyCode=56, no extra modifiers)
  "custom::40:1048576"   → ⌘+K (keyCode=40, command flag)
  "custom::56:131072"    → ⇧+Shift (if recording captures it this way)
```

**Why reuse `systemShortcutName`:**
- No changes to the `Codable` `ButtonBinding` struct
- No UserDefaults data migration needed
- All existing serialization, enable/disable, delete logic works unchanged
- `MosInputProcessor` routing only needs one `hasPrefix` check

#### Performance: Pre-parsing

To avoid string parsing on every event in the hot path, pre-parse `custom::` values at load time.

`ButtonBinding` is a value type (`struct`), so calling `prepareCustomCache()` on a returned copy won't persist. Instead, `ButtonUtils` maintains its own cached array:

```swift
class ButtonUtils {
    static let shared = ButtonUtils()

    // Cached bindings with pre-parsed custom fields
    private var cachedBindings: [ButtonBinding] = []
    private var isDirty = true

    func getButtonBindings() -> [ButtonBinding] {
        if isDirty {
            cachedBindings = Options.shared.buttons.binding.map { binding in
                var b = binding
                b.prepareCustomCache()
                return b
            }
            isDirty = false
        }
        return cachedBindings
    }

    func invalidateCache() {
        isDirty = true
    }
}
```

Call `invalidateCache()` whenever bindings change (in `syncViewWithOptions()` and `Options.readOptions()`).

Add transient cache fields on `ButtonBinding`:

```swift
struct ButtonBinding: Codable, Equatable {
    // ... existing fields ...

    // Transient cache, NOT part of Codable or Equatable
    private(set) var cachedCustomCode: UInt16? = nil
    private(set) var cachedCustomModifiers: UInt64? = nil

    mutating func prepareCustomCache() {
        guard systemShortcutName.hasPrefix("custom::") else { return }
        let parts = systemShortcutName.dropFirst(8).split(separator: ":")
        guard parts.count == 2,
              let code = UInt16(parts[0]),
              let mods = UInt64(parts[1]) else { return }
        cachedCustomCode = code
        // Clean redundant modifier flag: when binding a modifier key alone,
        // the recorded modifiers may include the key's own flag (e.g., Shift keyCode=56
        // with maskShift in modifiers). Strip the self-referencing flag to avoid doubling.
        var cleanedMods = mods
        if KeyCode.modifierKeys.contains(code) {
            let selfFlag = KeyCode.getKeyMask(code).rawValue
            cleanedMods = mods & ~selfFlag
        }
        cachedCustomModifiers = cleanedMods
    }

    // Exclude transient fields from Codable
    enum CodingKeys: String, CodingKey {
        case id, triggerEvent, systemShortcutName, isEnabled, createdAt
    }

    // Exclude transient fields from Equatable (use only coded fields)
    static func == (lhs: ButtonBinding, rhs: ButtonBinding) -> Bool {
        return lhs.id == rhs.id
            && lhs.triggerEvent == rhs.triggerEvent
            && lhs.systemShortcutName == rhs.systemShortcutName
            && lhs.isEnabled == rhs.isEnabled
            && lhs.createdAt == rhs.createdAt
    }
}
```

**Note on CodingKeys:** Adding explicit `CodingKeys` that match all existing property names produces identical encoding to the auto-synthesized version. No data migration needed. However, any future fields added to `ButtonBinding` must also be added to `CodingKeys` — add a code comment to flag this.

#### Display Name

Generate display text from cached code + modifiers using existing `KeyCode.keyMap` and modifier flag decomposition. This is the same logic `MosInputEvent.displayComponents` uses — extract into a shared utility if not already.

### 4. Execution Model: down/up Passthrough

#### Changes to ButtonCore (CRITICAL)

Current `eventMask` only includes Down events (`leftMouseDown`, `rightMouseDown`, `otherMouseDown`, `keyDown`). For custom binding down/up passthrough, Up events must also be captured.

Add to `ButtonCore.eventMask`:
- `otherMouseUp` (for side buttons and middle button)
- `keyUp` (for keyboard trigger bindings)

Note: `leftMouseUp`/`rightMouseUp` are intentionally omitted — binding left/right click as triggers is not a supported use case and intercepting their Up events could break normal mouse behavior.

#### Changes to RecordedEvent.matchesMosInput() (CRITICAL)

Current `matchesMosInput()` has `guard event.phase == .down` for keyboard events (line ~167). This must be removed so `.up` events can also match. The phase filtering is handled downstream in `ShortcutExecutor`, not at the matching level.

#### Changes to MosInputProcessor

Current: `guard event.phase == .down else { return .passthrough }` — only processes Down events.

New: Support both Down and Up via an **active bindings table**. This solves the critical problem where Up events may have different modifier flags than Down (e.g., user releases ⌘ before releasing the trigger button), which would cause `matchesMosInput()` to fail on Up and leave the bound key stuck.

```swift
class MosInputProcessor {
    static let shared = MosInputProcessor()

    // Active bindings: tracks which bindings are currently "held down"
    // Key: (EventType, keyCode) of the trigger event
    // Value: the matched ButtonBinding
    private var activeBindings: [TriggerKey: ButtonBinding] = [:]

    private struct TriggerKey: Hashable {
        let type: EventType
        let code: UInt16
    }

    func process(_ event: MosInputEvent) -> MosInputResult {
        let key = TriggerKey(type: event.type == .keyboard ? .keyboard : .mouse, code: event.code)

        if event.phase == .up {
            // On Up: look up by (type, code) only — ignore modifiers
            if let binding = activeBindings.removeValue(forKey: key) {
                ShortcutExecutor.shared.execute(
                    named: binding.systemShortcutName,
                    phase: .up,
                    binding: binding
                )
                return .consumed
            }
            return .passthrough
        }

        // On Down: full matching including modifiers
        let bindings = ButtonUtils.shared.getButtonBindings()
        for binding in bindings where binding.isEnabled {
            if binding.triggerEvent.matchesMosInput(event) {
                // Track this binding as active for Up pairing
                activeBindings[key] = binding
                ShortcutExecutor.shared.execute(
                    named: binding.systemShortcutName,
                    phase: .down,
                    binding: binding
                )
                return .consumed
            }
        }
        return .passthrough
    }
}
```

**Why active bindings table:**
- Down events use full matching (type + code + modifiers + device filter) — same as current behavior
- Up events use (type, code) lookup only — guaranteed to pair with the corresponding Down
- Automatic cleanup: `removeValue(forKey:)` returns and removes in one operation
- No stale entries: each Down overwrites, each Up removes
- Predefined SystemShortcut bindings also enter the table but their Up is ignored by `ShortcutExecutor` (`guard phase == .down`)

#### Changes to ShortcutExecutor

Add `phase` parameter to `execute(named:phase:binding:)`:

```swift
func execute(named shortcutName: String, phase: MosInputPhase, binding: ButtonBinding? = nil) {
    if let code = binding?.cachedCustomCode {
        // Custom binding: respect phase
        let modifiers = binding?.cachedCustomModifiers ?? 0
        executeCustom(code: code, modifiers: modifiers, phase: phase)
    } else if shortcutName.hasPrefix("logi") {
        // Logi: fire on down only (unchanged)
        guard phase == .down else { return }
        executeLogiAction(shortcutName)
    } else {
        // Predefined SystemShortcut: fire on down only (unchanged)
        guard phase == .down else { return }
        if let shortcut = SystemShortcut.shortcut(byName: shortcutName) {
            execute(shortcut)
        }
    }
}

private func executeCustom(code: UInt16, modifiers: UInt64, phase: MosInputPhase) {
    let source = CGEventSource(stateID: .hidSystemState)
    let isModifierKey = KeyCode.modifierKeys.contains(code)

    if isModifierKey {
        // Modifier keys use flagsChanged event type, not keyDown/keyUp
        guard let event = CGEvent(source: source) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        // On down: set the modifier flag; on up: clear it
        if phase == .down {
            let keyMask = KeyCode.getKeyMask(code)
            event.flags = CGEventFlags(rawValue: modifiers | keyMask.rawValue)
        } else {
            event.flags = CGEventFlags(rawValue: modifiers)
        }
        event.post(tap: .cghidEventTap)
    } else {
        // Regular keys use keyDown/keyUp
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: phase == .down) else { return }
        event.flags = CGEventFlags(rawValue: modifiers)
        event.post(tap: .cghidEventTap)
    }
}
```

**Key design decisions:**
- Use `CGEventSource(stateID: .hidSystemState)` — consistent with existing `ShortcutExecutor.execute(code:flags:)`
- Use `.cghidEventTap` for posting — consistent with existing executor, avoids self-interception by `ButtonCore` which listens at `.cgAnnotatedSessionEventTap`
- Modifier keys use `flagsChanged` event type — this is how macOS natively represents modifier state changes; `keyDown`/`keyUp` would not be recognized by apps as modifier presses
- Regular keys use `keyDown`/`keyUp` — standard keyboard event posting

**Key behavior:**
- Custom bindings: down → keyDown/flagsChanged, up → keyUp/flagsChanged (1:1 mapping)
- Predefined SystemShortcut: down only (unchanged behavior)
- Logi actions: down only (unchanged behavior)

### 5. UI Integration Details

#### Callback Signature Change (CRITICAL)

Current `onShortcutSelected` callback is `(SystemShortcut.Shortcut?) -> Void`. Custom bindings are not `SystemShortcut.Shortcut` objects. Solution: add a second callback for custom bindings.

```swift
// ButtonTableCellView — add alongside existing callback
private var onCustomShortcutRecorded: ((String) -> Void)?  // receives "custom::56:0"
```

`PreferencesButtonsViewController` provides this callback when configuring the cell:

```swift
// In tableView(_:viewFor:) cell configuration
cell.onCustomShortcutRecorded = { [weak self] customName in
    self?.updateButtonBinding(id: binding.id, withCustomName: customName)
}
```

Add `updateButtonBinding(id:withCustomName:)` to `PreferencesButtonsViewController`:

```swift
func updateButtonBinding(id: UUID, withCustomName name: String) {
    guard let index = buttonBindings.firstIndex(where: { $0.id == id }) else { return }
    // Note: ButtonBinding.init currently hardcodes createdAt = Date().
    // Modify init to accept optional createdAt parameter to preserve original timestamp.
    buttonBindings[index] = ButtonBinding(
        id: id,
        triggerEvent: buttonBindings[index].triggerEvent,
        systemShortcutName: name,
        isEnabled: true,
        createdAt: buttonBindings[index].createdAt
    )
    syncViewWithOptions()
    tableView.reloadData()
}
```

**Note:** `ButtonBinding.init` must be updated to accept an optional `createdAt` parameter (defaulting to `Date()`). This also fixes the existing `updateButtonBinding(id:with:)` which currently resets `createdAt` on every update.

This keeps the existing `onShortcutSelected` for predefined shortcuts unchanged.

#### KeyRecorder Lifecycle in Cell

Each `ButtonTableCellView` creates its own `KeyRecorder` instance — NOT shared with the ViewController's recorder (which is used for trigger key recording). This avoids delegate conflicts.

```swift
// ButtonTableCellView
private lazy var customRecorder: KeyRecorder = {
    let recorder = KeyRecorder()
    recorder.delegate = self
    return recorder
}()
```

Lifecycle management:
- `customRecorder` is lazily created on first "自定义…" click
- Cleanup in `configure()` method (not `prepareForReuse()` — `NSTableCellView` does not have a `prepareForReuse` callback like `UITableViewCell`). At the start of `configure()`, call `customRecorder.stopRecording()` to clean up if cell is recycled during recording
- The 0.5s post-recording delay in `KeyRecorder.stopRecording()` is acceptable because each cell has its own recorder — concurrent recordings on different cells won't conflict

#### ButtonTableCellView startCustomRecording()

```swift
private func startCustomRecording() {
    customRecorder.startRecording(from: actionPopUpButton, mode: .adaptive)
}
```

#### Display for Custom Bindings

When `systemShortcutName.hasPrefix("custom::")`:
- Parse code + modifiers → generate display components using `KeyCode.keyMap` and modifier flag decomposition
- Show in popup button placeholder with `⌨️` icon prefix (SF Symbol `keyboard`, macOS 11.0+; no icon on older systems)
- No category submenu highlight (custom is not in any submenu)

#### KeyRecorderDelegate Implementation in ButtonTableCellView

`ButtonTableCellView` conforms to `KeyRecorderDelegate` with two methods:

- `onEventRecorded(_:didRecordEvent:isDuplicate:)`: Convert `MosInputEvent` to `custom::<code>:<modifiers>` string. Call `onCustomShortcutRecorded?(customString)`. If `isDuplicate`, show highlight on existing row instead.
- `validateRecordedEvent(_:event:)`: Check if the recorded event (as a custom binding) conflicts with any existing binding. Return `false` if duplicate.

#### Re-recording (Changing Custom Binding)

User clicks popup → selects "自定义…" again → records new combination → replaces previous binding. Same flow, no special handling needed.

### 6. Scope Clarification

**Trigger keys (left column):** Recorded via existing `.combination` mode in `PreferencesButtonsViewController`. This is unchanged — triggers are mouse buttons, Logi buttons, or modifier+key combinations. Standalone modifier keys are NOT supported as triggers (because `ButtonCore.eventMask` does not include `flagsChanged`).

**Action keys (right column / "自定义…"):** Recorded via new `.adaptive` mode. This is where the new feature applies — actions support standalone modifiers, single keys, and modifier+key combinations.

## Test Coverage

### 5.1 Adaptive Recording Mode

| # | Scenario | Operation | Expected |
|---|----------|-----------|----------|
| 1 | Single regular key | Press `K` | Immediately record `K` |
| 2 | Single function key | Press `F5` | Immediately record `F5` |
| 3 | Combination key | Hold `⌘` → press `K` | Record `⌘+K` |
| 4 | Multi-modifier combination | Hold `⌘+⇧` → press `K` | Record `⌘+⇧+K` |
| 5 | Single modifier (quick release) | Press `⇧` → release → wait 300ms | Record `⇧` |
| 6 | Multi-modifier single press | Hold `⌘+⇧` → release all → wait 300ms | Record `⌘+⇧` |
| 7 | Release then reconsider | Press `⌘` → release → within 150ms press `⌘` → press `K` | Record `⌘+K` (timer cancelled) |
| 8 | Mouse side button | Press side button | Immediately record |
| 9 | Logi HID++ button | Press Logi button | Immediately record |
| 10 | ESC cancel | Press ESC during recording | Cancel, no result |
| 11 | Held modifier fallback | Hold `⌘` for 10s without release | Record `⌘` |
| 12 | No input timeout | Start recording, do nothing for 10s | Cancel recording |

### 5.2 Menu Interaction & Timing

| # | Scenario | Operation | Expected |
|---|----------|-----------|----------|
| 13 | Normal custom flow | Click "自定义…" | Menu closes → popover appears → can record |
| 14 | Window switch before popover | Click "自定义…" then ⌘+Tab | Observer fires, `window == nil` → no popover |
| 15 | Select predefined shortcut | Click "调度中心" | Normal binding, no recording popover |
| 16 | Unbind | Click "取消绑定" | Binding cleared, no recording popover |
| 17 | Observer cleanup | Click "自定义…" then complete recording | Observer removed, subsequent menu operations unaffected |

### 5.3 Data Model & Persistence

| # | Scenario | Operation | Expected |
|---|----------|-----------|----------|
| 18 | Serialization | Save `custom::56:0` binding | UserDefaults written correctly, survives restart |
| 19 | Display (single modifier) | Load `custom::56:0` | UI shows "⇧ Shift" |
| 20 | Display (combination) | Load `custom::40:1048576` | UI shows "⌘+K" |
| 21 | Pre-parse cache | Load bindings with custom entries | `cachedCustomCode`/`cachedCustomModifiers` populated |
| 22 | Coexistence | Both predefined and custom bindings | Both display and execute correctly |

### 5.4 Execution Model (down/up)

| # | Scenario | Operation | Expected |
|---|----------|-----------|----------|
| 23 | Custom single modifier down/up | Side button bound to `⇧`: press → release | flagsChanged(⇧ down) → flagsChanged(⇧ up), 1:1 |
| 24 | Custom combo down/up | Side button bound to `⌘+K`: press → release | keyDown(⌘+K) → keyUp(⌘+K) |
| 25 | Predefined unaffected | Side button bound to "Mission Control": press → release | Only down triggers, up ignored |
| 26 | Rapid press | Side button bound to `⇧`: rapid press-release-press-release | Correct down-up-down-up sequence |
| 27 | Long hold | Side button bound to `⇧`: hold 3s | ⇧ held, other keys can combine |

### 5.5 Active Bindings Table (Up Event Pairing)

| # | Scenario | Operation | Expected |
|---|----------|-----------|----------|
| 28 | Modifier released before trigger | Bind ⌘+Side3 → custom ⇧: hold ⌘, press Side3, release ⌘, release Side3 | Down matches (⌘+Side3), Up pairs via (mouse, Side3) lookup — ⇧ released correctly |
| 29 | Clean Up pairing | Press Side3 (bound to ⇧) → release Side3 | activeBindings entry removed on Up, no stale entries |
| 30 | Multiple concurrent triggers | Press Side3 (→⇧) then press Side4 (→⌘) then release Side3 then release Side4 | Each trigger independently tracked and released |

### 5.6 Edge Cases

| # | Scenario | Operation | Expected |
|---|----------|-----------|----------|
| 31 | Duplicate detection | Record existing custom key | Detected, existing row highlighted |
| 32 | Custom replaces custom | Same trigger: change from `⇧` to `⌘+K` | Correctly updated |
| 33 | Custom replaces predefined | Same trigger: "Mission Control" → custom `⇧` | Switches execution path |
| 34 | Predefined replaces custom | Same trigger: custom `⇧` → "Mission Control" | Restores predefined path, up no longer responds |
| 35 | Invalid custom string | `custom::abc:xyz` in storage | Graceful degradation, binding disabled or ignored |

## Files to Modify

| File | Changes |
|------|---------|
| `Mos/Keys/KeyRecorder.swift` | Add `.adaptive` mode, adaptive state machine, two timers |
| `Mos/Shortcut/ShortcutManager.swift` | Add "自定义…" menu item with separator |
| `Mos/Windows/PreferencesWindow/ButtonsView/ButtonTableCellView.swift` | Handle custom menu selection, NSMenu notification, own KeyRecorder instance, `KeyRecorderDelegate`, display custom bindings, `onCustomShortcutRecorded` callback |
| `Mos/Windows/PreferencesWindow/ButtonsView/PreferencesButtonsViewController.swift` | Add `onCustomShortcutRecorded` callback wiring in cell config, add `updateButtonBinding(id:withCustomName:)` method |
| `Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift` | Add `cachedCustomCode`/`cachedCustomModifiers` transient fields, `prepareCustomCache()` with modifier flag cleanup, explicit `CodingKeys` and `Equatable`, remove `.down` guard from `matchesMosInput()` |
| `Mos/ButtonCore/ButtonCore.swift` | Add `otherMouseUp` and `keyUp` to `eventMask` |
| `Mos/ButtonCore/ButtonUtils.swift` | Add cached bindings array with `prepareCustomCache()` pre-processing, `invalidateCache()` |
| `Mos/InputEvent/MosInputProcessor.swift` | Remove `.down`-only guard, pass phase to executor |
| `Mos/Shortcut/ShortcutExecutor.swift` | Add `phase` parameter, `executeCustom()` with modifier/regular key branching, use `.hidSystemState` source and `.cghidEventTap` posting |
| `Mos/Logi/LogitechDeviceSession.swift` | Update independent binding matching path (~line 1564-1575): remove `if isDown` guard, pass phase to `MosInputProcessor` or update to use new `execute(named:phase:binding:)` signature. Ensure Logi button Up events also reach the active bindings table |
| `Mos/Extension/CGEvent+Extensions.swift` | Add `otherMouseUp`, `keyUp` to `isMouseEvent` recognition (future-proofing, not currently used in MosInputEvent init path but prevents misclassification) |
| `Mos/Localizable.xcstrings` | Add "自定义…" localization key |

## Files NOT Modified

| File | Reason |
|------|--------|
| `KeyPopover.swift` | Reused as-is |
| `KeyPreview.swift` | Reused as-is |
| `KeyCode.swift` | No new key codes needed |
| `SystemShortcut.swift` | Custom bindings bypass SystemShortcut entirely |
| `Options.swift` | No schema changes (call `ButtonUtils.shared.invalidateCache()` in existing `readOptions()`) |
