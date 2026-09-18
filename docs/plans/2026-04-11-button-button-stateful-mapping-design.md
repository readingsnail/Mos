# Button-Button Stateful Mapping Design

## Overview

Add true `down/up` stateful mapping for actions in the existing mouse-button action category so a trigger button can map to another mouse button without collapsing into a one-shot click. Keep all non-mouse action categories on the current trigger-style execution path. Reuse the existing `down/up` pairing model already proven by custom bindings, while decoupling "stateful execution" from the `custom::` encoding itself.

## Problem Statement

Today the button binding pipeline supports two different execution behaviors:

- Custom bindings encoded as `custom::<code>:<modifiers>` already execute with explicit `down/up` phases.
- Predefined mouse actions such as `mouseLeftClick` and `mouseRightClick` still execute as an immediate synthetic `down + up` pair inside one call.

That means a mapping like "side button -> left mouse button" is treated as a synthetic click, not as a real held button state. The user-visible symptom is that button-button mapping cannot preserve held-state semantics.

## Goals

- Support true `down/up` stateful execution for the existing mouse-button action category.
- Keep all other existing action categories on the current trigger execution model.
- Reuse the current `activeBindings` pairing pattern instead of building a second state system.
- Cleanly separate action payload encoding from execution semantics.
- Preserve a straightforward path to make additional categories stateful in the future.
- Rename `MosInputEvent` and `MosInputProcessor` to `InputEvent` and `InputProcessor` for clearer module ownership.
- Keep the hot path lean with no new movement-event handling or polling.

## Non-Goals

- No explicit handling of `mouseMoved`, `leftMouseDragged`, `rightMouseDragged`, or `otherMouseDragged`.
- No redesign of the Buttons UI.
- No change to the `custom::` storage format.
- No attempt to generalize every action category to stateful execution in this iteration.

## Current Architecture Summary

The current pipeline is:

1. `ButtonCore` converts physical `CGEvent` input into `MosInputEvent`.
2. `MosInputProcessor` matches the event against `ButtonBinding.triggerEvent`.
3. `ShortcutExecutor` executes the matched action.
4. `activeBindings` is used only for flows that already need paired `down/up` release.

This architecture is already close to what we need. The main issue is that "stateful" currently means "custom binding" rather than being a first-class execution mode.

## Design

### 1. Rename the input layer

Rename the input model and processor files and types:

- `Mos/InputEvent/MosInputEvent.swift` -> `Mos/InputEvent/InputEvent.swift`
- `Mos/InputEvent/MosInputProcessor.swift` -> `Mos/InputEvent/InputProcessor.swift`
- `MosInputEvent` -> `InputEvent`
- `MosInputPhase` -> `InputPhase`
- `MosInputSource` -> `InputSource`
- `MosInputDevice` -> `InputDevice`
- `MosInputResult` -> `InputResult`
- `MosInputProcessor` -> `InputProcessor`

This is a naming cleanup only. No behavior changes should be attached to the rename beyond reference updates.

### 2. Introduce explicit action execution modes

Add a small execution-mode abstraction:

```swift
enum ActionExecutionMode {
    case trigger
    case stateful
}
```

This mode belongs to the action definition layer, not to the input event layer and not to the storage encoding itself.

Initial policy:

- Mouse-button action category -> `.stateful`
- All other predefined categories -> `.trigger`
- Custom bindings -> `.stateful`

This turns "stateful" into an execution property that multiple action types can share.

### 3. Introduce a resolved action representation

Before execution, parse a binding's output action into a single internal representation:

```swift
enum ResolvedAction {
    case customKey(code: UInt16, modifiers: UInt64)
    case mouseButton(kind: MouseButtonActionKind)
    case systemShortcut(identifier: String)
    case logiAction(identifier: String)
}
```

`MouseButtonActionKind` should map the current mouse-button category actions to semantic outputs:

```swift
enum MouseButtonActionKind {
    case left
    case right
    case middle
    case back
    case forward
}
```

`ShortcutExecutor` should operate on `ResolvedAction`, not on a mix of ad-hoc string prefixes and special cases spread across the pipeline.

### 4. Store active stateful sessions, not just raw bindings

Replace the current "active trigger key -> binding" storage with a lightweight session object:

```swift
struct ActiveBindingSession {
    let triggerKey: TriggerKey
    let bindingId: UUID
    let action: ResolvedAction
    let executionMode: ActionExecutionMode
}
```

The active table remains keyed by trigger source:

```swift
[TriggerKey: ActiveBindingSession]
```

Why this change:

- `up` handling does not need to re-parse strings or re-read menu definitions.
- Custom-key stateful actions and mouse-button stateful actions share the same release path.
- Future stateful action categories can reuse the same session model.

### 5. Keep `InputProcessor` responsible for pairing

`InputProcessor` should remain the owner of:

- binding matching
- `down/up` pairing
- active session lifecycle
- fail-safe release of all active stateful outputs

Behavior by phase:

#### Down

1. Match the incoming `InputEvent` against enabled bindings.
2. Resolve the output action.
3. Inspect its execution mode.
4. If `.trigger`, execute immediately and do not record active state.
5. If `.stateful`, execute the action's `down`, store an `ActiveBindingSession`, then consume.

#### Up

1. Look up the trigger source in the active session table.
2. If found, execute the stored action's `up`, remove the session, then consume.
3. If not found, passthrough.

This preserves the existing custom-binding release model and broadens it to mouse-button outputs.

### 6. Keep modifier injection scoped to custom modifier bindings

`activeModifierFlags` should continue to be derived from active sessions, but only from sessions whose resolved action is a custom modifier key.

That means:

- Stateful mouse-button actions can live in the same active table.
- They do not interfere with virtual modifier injection.
- No extra modifier state system is needed.

### 7. Make mouse-button actions phase-aware in `ShortcutExecutor`

Mouse-button actions in the existing category should stop using one-shot click helpers. Instead they should use a phase-aware posting path:

- `down` -> post synthetic mouse-down event
- `up` -> post synthetic mouse-up event

This should be handled through a dedicated helper, for example:

```swift
func executeMouseButton(_ kind: MouseButtonActionKind, phase: InputPhase)
```

Coordinate policy remains simple:

- Use the current cursor position at post time.
- Do not synthesize motion events.
- Do not rewrite the pointer location.

This keeps the behavior aligned with the current design boundary.

### 8. Retain trigger behavior for all other actions

All existing non-mouse predefined actions continue to behave exactly as trigger actions:

- execute only on `down`
- ignore `up`
- do not enter the active session table

That keeps the existing UX and avoids accidental semantic changes to the rest of the shortcuts catalog.

## Event Flow

### Example A: Side Button -> Left Mouse Button

1. Physical side-button `down` arrives in `ButtonCore`.
2. `ButtonCore` builds an `InputEvent`.
3. `InputProcessor` matches the binding.
4. Binding resolves to `.mouseButton(.left)` with `.stateful`.
5. `ShortcutExecutor` posts synthetic left-mouse `down`.
6. `InputProcessor` stores an `ActiveBindingSession`.
7. Physical side-button `up` arrives later.
8. `InputProcessor` looks up the session.
9. `ShortcutExecutor` posts synthetic left-mouse `up`.
10. Session is removed.

### Example B: Side Button -> Mission Control

1. Physical side-button `down` arrives.
2. Binding resolves to `.systemShortcut("missionControl")` with `.trigger`.
3. `ShortcutExecutor` executes it immediately.
4. No active session is stored.
5. Physical side-button `up` later passes through with no further work.

### Example C: Side Button -> Custom Modifier Key

1. Physical side-button `down` arrives.
2. Binding resolves to `.customKey(...)` with `.stateful`.
3. `ShortcutExecutor` posts the synthetic key `down`.
4. `InputProcessor` stores the session.
5. `activeModifierFlags` is recomputed from active sessions and injected into passthrough keyboard events.
6. On source `up`, the synthetic custom key `up` is posted and the session is removed.

This shows that custom bindings and stateful mouse-button bindings share the same session lifecycle but keep separate payload semantics.

## Fail-Safe Release Strategy

The biggest correctness risk is a stuck synthetic held output. To prevent that, `clearActiveBindings()` should evolve into a real "release all active sessions" operation:

1. Iterate every active session.
2. For sessions with `.stateful`, execute their `up`.
3. Clear the table.
4. Recompute `activeModifierFlags`.

This unified release path must be called when:

- event tap is disabled by timeout
- event tap is disabled by user input
- accessibility permission is revoked
- `ButtonCore.disable()` is called
- `Interceptor` restarts
- app shutdown or equivalent subsystem teardown happens

This strategy keeps release logic in one place and applies equally to custom-key stateful output and mouse-button stateful output.

## Performance Considerations

The design keeps performance costs low:

- No new movement-event interception.
- No new polling.
- No additional global state scan beyond the active-session recomputation already used for virtual modifiers.
- No repeated parsing on `up`, because resolved actions are stored in the active session.

This keeps the hot path close to the existing model while making the behavior more correct.

## File-Level Impact

Primary files:

- `Mos/InputEvent/InputEvent.swift`
- `Mos/InputEvent/InputProcessor.swift`
- `Mos/Shortcut/SystemShortcut.swift`
- `Mos/Shortcut/ShortcutExecutor.swift`
- `Mos/ButtonCore/ButtonCore.swift`
- `Mos/LogitechHID/LogitechDeviceSession.swift`

Likely tests:

- `MosTests/MosInputProcessorTests.swift` renamed or replaced with `MosTests/InputProcessorTests.swift`
- new focused executor tests for mouse-button stateful behavior if practical

## Testing Strategy

The most important validation cases are:

- side button -> left mouse button posts `down` on source `down` and `up` on source `up`
- side button -> right mouse button behaves the same way
- HID++ source button -> mouse-button category action follows the same lifecycle
- repeated rapid `down/up` pairs do not leave stale active sessions
- timeout / disable / revoke flows release all active stateful outputs
- custom modifier bindings still recompute `activeModifierFlags` correctly
- non-mouse predefined actions still remain trigger-only

## Open Tradeoff

The internal identifiers in the mouse-button category still use `mouseLeftClick`, `mouseRightClick`, and similar names. Their execution semantics will become stateful instead of one-shot click semantics. This is acceptable for the current iteration because:

- the UI category remains familiar
- the user intent is clearly mouse-button output
- we avoid a disruptive naming migration

If we later need to distinguish one-shot click from held-state output, we can add new identifiers and migrate the menu labeling separately.

## Recommendation

Proceed with a small abstraction step:

- rename `MosInput*` to `Input*`
- add explicit execution modes
- add resolved-action parsing
- expand the existing active-session model to all stateful actions
- make only the mouse-button category stateful for now

This keeps the design aligned with the current framework, minimizes branching, and leaves a clean extension path for future stateful categories.
