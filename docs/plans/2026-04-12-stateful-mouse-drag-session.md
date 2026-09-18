# Stateful Mouse Drag Session Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make mapped mouse-button actions produce real cross-app drag behavior by rewriting movement events into the correct `*MouseDragged` stream only while a synthetic mouse-button session is active.

**Architecture:** Keep `InputProcessor` as the generic stateful session manager, introduce explicit `ActiveBindingSession` data plus indexed binding lookup, and add a dedicated `MouseDragSessionController` that owns a reusable motion tap. The motion tap activates only during synthetic mouse sessions and rewrites in-flight move events instead of reposting new ones.

**Tech Stack:** Swift, AppKit, CoreGraphics `CGEvent`, existing `Interceptor`, `ButtonCore`, `InputProcessor`, `ShortcutExecutor`, and `xcodebuild test`

---

### Task 1: Add failing tests for drag-target logic and indexed binding lookup

**Files:**
- Create: `MosTests/MouseDragSessionControllerTests.swift`
- Modify: `MosTests/InputProcessorTests.swift`

**Step 1: Write the failing tests**

Add logic-level tests for:

- synthetic priority:

```swift
func testSyntheticTargetPriority_leftBeatsRightAndOther()
```

- effective target selection:

```swift
func testEffectiveTarget_prefersPhysicalLeftOverSyntheticRight()
func testEffectiveTarget_upgradesMouseMovedToSyntheticLeftDragged()
```

- drag-session lifecycle:

```swift
func testSessionLifecycle_startsOnFirstMouseSession_andStopsOnLast()
```

- binding index:

```swift
func testButtonUtilsIndex_returnsOnlyMatchingTypeAndCodeCandidates()
```

**Step 2: Run the focused tests to verify they fail**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MouseDragSessionControllerTests -only-testing:MosTests/InputProcessorTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
```

Expected: compile or test failure because the drag-session controller and indexed lookup do not exist yet.

**Step 3: Commit nothing yet**

Do not commit in red state.

### Task 2: Introduce indexed binding lookup in `ButtonUtils`

**Files:**
- Modify: `Mos/ButtonCore/ButtonUtils.swift`
- Modify: `Mos/InputEvent/InputProcessor.swift`
- Test: `MosTests/InputProcessorTests.swift`

**Step 1: Add a trigger-key cache**

Add a lightweight key model in `ButtonUtils`:

```swift
struct ButtonBindingTriggerKey: Hashable {
    let type: EventType
    let code: UInt16
}
```

Maintain:

```swift
private var cachedBindings: [ButtonBinding] = []
private var cachedBindingsByTriggerKey: [ButtonBindingTriggerKey: [ButtonBinding]] = [:]
```

**Step 2: Build the index when cache is refreshed**

Populate both caches during `getButtonBindings()` and expose:

```swift
func getButtonBindings(for type: EventType, code: UInt16) -> [ButtonBinding]
```

**Step 3: Update `InputProcessor` to use indexed candidates**

Change `down` matching from full-list scan to:

```swift
let candidates = ButtonUtils.shared.getButtonBindings(for: event.type, code: event.code)
for binding in candidates where binding.isEnabled { ... }
```

**Step 4: Run tests**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/InputProcessorTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
```

Expected: the new binding-index tests pass and existing processor tests stay green.

**Step 5: Commit**

```bash
git add Mos/ButtonCore/ButtonUtils.swift Mos/InputEvent/InputProcessor.swift MosTests/InputProcessorTests.swift
git commit -m "perf(buttons): index bindings by trigger key"
```

### Task 3: Replace raw active actions with explicit active sessions

**Files:**
- Modify: `Mos/InputEvent/InputProcessor.swift`
- Modify: `Mos/Shortcut/ShortcutExecutor.swift`
- Test: `MosTests/InputProcessorTests.swift`

**Step 1: Add `ActiveBindingSession`**

Replace the current active map value:

```swift
private struct ActiveBindingSession {
    let triggerKey: TriggerKey
    let action: ResolvedAction
    let mouseSessionID: UUID?
}
```

**Step 2: Update `down/up` handling to store sessions**

On stateful `down`:

- end any previous session for the same trigger key
- call the executor
- store the returned mouse session ID if the action is a mouse-button action

On `up`:

- load the stored session
- release through the executor/backend
- remove the session

**Step 3: Keep `clearActiveBindings()` authoritative**

Iterate sessions, release each stateful action, then clear modifier flags and all session state.

**Step 4: Run tests**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/InputProcessorTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
```

Expected: session-pairing tests remain green and new mouse-session storage behavior passes.

**Step 5: Commit**

```bash
git add Mos/InputEvent/InputProcessor.swift Mos/Shortcut/ShortcutExecutor.swift MosTests/InputProcessorTests.swift
git commit -m "refactor(input): store explicit active binding sessions"
```

### Task 4: Build `MouseDragSessionController` with pure selection logic first

**Files:**
- Create: `Mos/InputEvent/MouseDragSessionController.swift`
- Test: `MosTests/MouseDragSessionControllerTests.swift`

**Step 1: Add pure target models**

Create:

```swift
enum SyntheticMouseTarget: Equatable {
    case left
    case right
    case other(buttonNumber: Int64)
}

enum PhysicalMouseTarget: Equatable {
    case none
    case left
    case right
    case other(buttonNumber: Int64)
}
```

Add pure helpers:

```swift
static func dominantSyntheticTarget(from targets: [SyntheticMouseTarget]) -> SyntheticMouseTarget?
static func effectiveTarget(physical: PhysicalMouseTarget, synthetic: SyntheticMouseTarget?) -> SyntheticMouseTarget?
```

**Step 2: Add session bookkeeping**

Create a controller with:

```swift
final class MouseDragSessionController {
    static let shared = MouseDragSessionController()
}
```

Track:

- active mouse sessions by UUID
- dominant synthetic target cache

Do not wire the motion tap yet.

**Step 3: Run tests**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MouseDragSessionControllerTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
```

Expected: priority and effective-target tests pass.

**Step 4: Commit**

```bash
git add Mos/InputEvent/MouseDragSessionController.swift MosTests/MouseDragSessionControllerTests.swift
git commit -m "feat(mouse): add drag target selection controller"
```

### Task 5: Add a reusable motion tap and in-place event rewriting

**Files:**
- Modify: `Mos/InputEvent/MouseDragSessionController.swift`
- Possibly Modify: `Mos/Utils/Interceptor.swift`
- Test: `MosTests/MouseDragSessionControllerTests.swift`

**Step 1: Wire a reusable `Interceptor`**

Create a motion tap that listens for:

- `mouseMoved`
- `leftMouseDragged`
- `rightMouseDragged`
- `otherMouseDragged`

The controller should:

- create the interceptor once
- `start()` it on first active mouse session
- `stop()` it when the last active mouse session ends

**Step 2: Rewrite movement events in place**

Implement:

```swift
func rewriteMotionEventIfNeeded(_ event: CGEvent) -> CGEvent
```

Rules:

- if no synthetic target, return event unchanged
- derive physical target from incoming event type
- compute effective target
- rewrite `event.type`
- update `mouseEventButtonNumber` for `otherMouseDragged` when needed
- do not repost a second event

**Step 3: Hook controller restart safety**

If the motion tap is disabled or restarted:

- clear all active input bindings through the shared release path
- do not silently keep a partially broken drag session alive

**Step 4: Run tests**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/MouseDragSessionControllerTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
```

Expected: lifecycle and rewrite tests pass.

**Step 5: Commit**

```bash
git add Mos/InputEvent/MouseDragSessionController.swift Mos/Utils/Interceptor.swift MosTests/MouseDragSessionControllerTests.swift
git commit -m "feat(mouse): rewrite movement events during synthetic drag sessions"
```

### Task 6: Integrate mouse sessions with `ShortcutExecutor`

**Files:**
- Modify: `Mos/Shortcut/ShortcutExecutor.swift`
- Modify: `Mos/InputEvent/InputProcessor.swift`
- Test: `MosTests/InputProcessorTests.swift`

**Step 1: Add explicit mouse session begin/end helpers**

Refactor mouse execution to return and consume session IDs:

```swift
func beginMouseButtonSession(_ kind: MouseButtonActionKind) -> UUID?
func endMouseButtonSession(id: UUID, kind: MouseButtonActionKind)
```

Use them from the stateful mouse-button path.

**Step 2: Preserve ordering**

On `down`:

- register drag session
- then post synthetic mouse down

On `up`:

- unregister drag session
- then post synthetic mouse up

**Step 3: Ensure `clearActiveBindings()` ends backend sessions**

Releasing an active mouse session must also disable the drag backend when it becomes empty.

**Step 4: Run tests**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/InputProcessorTests -only-testing:MosTests/MouseDragSessionControllerTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
```

Expected: integration tests pass.

**Step 5: Commit**

```bash
git add Mos/Shortcut/ShortcutExecutor.swift Mos/InputEvent/InputProcessor.swift MosTests/InputProcessorTests.swift MosTests/MouseDragSessionControllerTests.swift
git commit -m "feat(mouse): connect drag sessions to stateful mouse actions"
```

### Task 7: Expand source event coverage in `ButtonCore`

**Files:**
- Modify: `Mos/ButtonCore/ButtonCore.swift`
- Test: `MosTests/InputProcessorTests.swift`

**Step 1: Add missing mouse button source events**

Ensure the main event mask covers:

- `leftMouseDown`
- `leftMouseUp`
- `rightMouseDown`
- `rightMouseUp`
- `otherMouseDown`
- `otherMouseUp`

Keep keyboard passthrough logic unchanged.

**Step 2: Keep fail-safe cleanup unified**

On tap disable or shutdown, continue to call:

```swift
InputProcessor.shared.clearActiveBindings()
```

**Step 3: Run tests**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' -only-testing:MosTests/InputProcessorTests CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
```

Expected: stateful up-pairing tests still pass for any supported mouse source.

**Step 4: Commit**

```bash
git add Mos/ButtonCore/ButtonCore.swift MosTests/InputProcessorTests.swift
git commit -m "fix(buttons): cover full mouse source down and up events"
```

### Task 8: Run full verification and capture manual validation checklist

**Files:**
- Modify: `docs/plans/2026-04-12-stateful-mouse-drag-session.md`

**Step 1: Run full automated verification**

Run:

```bash
xcodebuild test -project Mos.xcodeproj -scheme Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=''
git diff --check
```

Expected:

- all tests pass
- no diff-check whitespace or merge-marker problems

**Step 2: Record manual verification checklist in the plan**

Append a checked or unchecked checklist for:

- Safari text drag selection
- Finder desktop selection
- Finder window drag/selection
- TextEdit/native text field drag selection
- Xcode editor selection
- Chrome control case

**Step 3: Commit**

```bash
git add docs/plans/2026-04-12-stateful-mouse-drag-session.md
git commit -m "docs(plan): record drag-session verification checklist"
```
