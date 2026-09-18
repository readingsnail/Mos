# Stateful Mouse Drag Session Design

## Overview

Extend the existing stateful mouse-button mapping so held mappings behave like real mouse drags across apps. Keep the generic `down/up` session framework in `InputProcessor`, and add a dedicated mouse drag backend that only activates while a mapped mouse-button session is held.

## Problem Statement

The current implementation correctly maps mouse-button actions as true `down/up` pairs, but many apps do not treat the interaction as a drag. Safari provided the clearest evidence:

- Physical left drag produced `leftMouseDown -> leftMouseDragged* -> leftMouseUp`
- Mapped side-button drag produced `leftMouseDown -> mouseMoved* -> leftMouseUp`

That means the missing capability is not held-button state itself, but the drag-phase event stream.

## Goals

- Preserve the current generic stateful action framework
- Add real drag semantics for mapped mouse-button actions
- Avoid permanently intercepting mouse movement
- Avoid consuming and reposting extra synthetic move/drag events
- Keep idle-path overhead effectively unchanged
- Preserve future extensibility for other stateful backends
- Improve hot-path matching so frequent clicks do not scale with total binding count

## Non-Goals

- No permanent move-event interception
- No app-specific hacks
- No pointer relocation logic
- No UI/config changes for this feature
- No generalized motion backend for non-mouse actions in this iteration

## Current Constraints

The current stateful mapping already works for:

- synthetic mouse `down/up`
- custom-key `down/up`
- unified fail-safe release through `InputProcessor.clearActiveBindings()`

The missing piece is that movement remains outside the stateful session model, so apps only see ordinary `mouseMoved` instead of button-specific drag events.

## Recommended Architecture

### 1. Keep a generic stateful session core

`InputProcessor` remains responsible for:

- matching trigger bindings
- deciding `trigger` vs `stateful`
- pairing `down/up`
- clearing active sessions on failure or teardown

This layer stays generic and does not directly process movement events.

### 2. Introduce `ActiveBindingSession`

Replace the current lightweight active-action storage with an explicit session model:

```swift
struct ActiveBindingSession {
    let triggerKey: TriggerKey
    let action: ResolvedAction
    let mouseSessionID: UUID?
}
```

This keeps the generic session framework intact while allowing mouse actions to attach backend-specific session state.

### 3. Add a dedicated `MouseDragSessionController`

This new backend owns all drag-phase mouse behavior:

- register active synthetic mouse-button sessions
- compute the dominant synthetic drag target
- lazily enable a motion tap while any synthetic mouse session is active
- disable the motion tap immediately when the last synthetic mouse session ends
- rewrite in-flight movement events into the correct `*MouseDragged` type

This controller is the only new component that knows about drag rewriting.

### 4. Keep `ShortcutExecutor` as the integration point

`ShortcutExecutor` remains the execution layer, but mouse-button actions become two-phase backend operations:

- `down`
  - ensure drag backend session is registered
  - post synthetic mouse `down`
- `up`
  - unregister drag backend session
  - post synthetic mouse `up`

`InputProcessor` still calls a single execution entry point. Mouse-specific complexity stays behind the backend.

## Event Model

### Session begin

When a mapped mouse-button action receives `down`:

1. `InputProcessor` matches the binding
2. The resolved action is `.mouseButton(...)`
3. `ShortcutExecutor` requests a mouse drag session from `MouseDragSessionController`
4. If needed, the controller enables its reusable motion tap
5. `ShortcutExecutor` posts the synthetic mouse `down`
6. `InputProcessor` stores an `ActiveBindingSession`

### Session end

When the paired trigger receives `up`:

1. `InputProcessor` looks up the active session
2. `ShortcutExecutor` ends the drag session
3. `MouseDragSessionController` removes that session
4. If no mouse sessions remain, the controller disables its motion tap
5. `ShortcutExecutor` posts the synthetic mouse `up`

### Movement handling

While at least one mapped mouse-button session is active, the motion tap listens for:

- `mouseMoved`
- `leftMouseDragged`
- `rightMouseDragged`
- `otherMouseDragged`

If there is no active synthetic mouse session, the event passes through unchanged.

If there is an active synthetic mouse session, the event is rewritten in place:

- `event.type`
- `mouseEventButtonNumber` when needed for `otherMouseDragged`

No additional synthetic movement event is posted.

## Drag Target Selection

The controller chooses an effective drag target using both real and synthetic state.

### Synthetic target

Synthetic target comes from active mapped mouse sessions and follows this priority:

1. `left`
2. `right`
3. `other(buttonNumber)`

This matches observed system behavior where left-button drag dominates if multiple buttons are held.

### Physical target

Physical target comes from the original incoming event:

- `leftMouseDragged` -> `left`
- `rightMouseDragged` -> `right`
- `otherMouseDragged` -> `other(buttonNumber)`
- `mouseMoved` -> `none`

### Effective target

The rewritten event uses:

`effective target = max(physical target, synthetic target)`

This prevents us from downgrading a real left drag and lets synthetic left drag dominate lower-priority drag states.

## Performance Strategy

### 1. No permanent movement interception

The motion tap exists as a reusable object, but it is only enabled while synthetic mouse sessions are active.

Idle path cost:

- unchanged main button tap
- no active movement rewrite tap

### 2. No reposted move events

The controller rewrites the current event object and returns it instead of:

- dropping the original event
- generating a second synthetic dragged event

This minimizes event volume, timing distortion, and invisible extra work.

### 3. Index bindings by trigger key

Current `InputProcessor` matching scans all enabled bindings on each `down`. That is acceptable for low rates, but frequent clicks should not scale with total binding count.

`ButtonUtils` should maintain:

- cached full binding list
- cached dictionary by `(event.type, code)`

Then `InputProcessor` only performs exact modifier/device checks on a small candidate list.

### 4. Reuse the motion tap

`MouseDragSessionController` should create its `Interceptor` once and toggle `start()/stop()` instead of repeatedly creating and destroying event taps for each click.

## Stability and Fail-Safe Rules

The worst failure mode is a stuck synthetic held mouse button. To prevent that:

- `InputProcessor.clearActiveBindings()` remains the single release authority
- clearing active bindings must also end all active drag sessions
- if either the main button tap or motion tap is disabled, all active sessions are cleared
- on permission loss, module disable, restart, or shutdown, all stateful outputs are released

The drag backend must never try to recover a broken live session silently. It should clear state and wait for a fresh user action.

## Source Event Coverage

The main button tap should fully support mouse button sources:

- `leftMouseDown`
- `leftMouseUp`
- `rightMouseDown`
- `rightMouseUp`
- `otherMouseDown`
- `otherMouseUp`

This keeps the stateful framework complete for any mouse-button trigger source.

## File-Level Responsibilities

- `Mos/InputEvent/InputProcessor.swift`
  - store `ActiveBindingSession`
  - maintain generic session pairing
  - clear all active state on failure
- `Mos/Shortcut/ShortcutExecutor.swift`
  - integrate mouse begin/end session behavior
  - keep mouse-button posting logic phase-aware
- `Mos/ButtonCore/ButtonUtils.swift`
  - add trigger-key binding index
- `Mos/ButtonCore/ButtonCore.swift`
  - ensure full mouse source coverage and shared fail-safe clearing
- `Mos/Utils/Interceptor.swift`
  - reused as-is if current `start()/stop()` lifecycle remains sufficient
- `Mos/InputEvent/MouseDragSessionController.swift`
  - new drag backend

## Testing Strategy

### Unit tests

- synthetic target priority: `left > right > other`
- effective target selection from physical + synthetic state
- motion tap lifecycle on first/last active mouse session
- clearing active bindings releases mouse sessions
- non-mouse stateful actions do not activate drag rewriting
- trigger-key index returns only relevant binding candidates

### Event-level validation

Use monitor logs to confirm:

- physical left drag still yields `leftMouseDragged`
- mapped side-button-to-left drag yields `leftMouseDragged`
- mapped right-button drag yields `rightMouseDragged`
- mapped other-button drag yields `otherMouseDragged` with correct button number

### Manual app validation

- Safari text selection
- Finder desktop box selection
- Finder window drag / selection
- TextEdit or native text field drag selection
- Xcode editor selection
- Chrome as control

## Design Summary

This design keeps the new complexity where it belongs:

- generic state stays in `InputProcessor`
- action execution stays in `ShortcutExecutor`
- drag semantics live in a dedicated mouse backend

That gives us real drag behavior without permanently intercepting movement, without reposting extra events, and without turning the whole input stack into mouse-specific logic.
