# CVDisplayLink Recovery & Core Event Processing Tests

## Problem

After macOS sleep/wake, the CVDisplayLink in ScrollPoster becomes invalid because display identifiers change. The CGEventTap continues to consume original scroll events (`return nil`), but ScrollPoster cannot post smooth replacement events because its CVDisplayLink is dead. Result: complete global scroll failure until Mos is restarted.

### Root Cause Chain

```
macOS sleep
  -> willSleepNotification -> disable() -> ScrollPoster.stop()
     (CVDisplayLink stopped but object retained, bound to old displays)
  -> System sleeps -> displays disconnect

macOS wake
  -> didWakeNotification fires (displays may NOT be ready yet!)
  -> enable() -> ScrollPoster.create()
  -> CVDisplayLinkCreateWithActiveCGDisplays fails (display count = 0, error -6661)
  -> poster becomes nil or zombie

User scrolls
  -> CGEventTap intercepts event (Interceptor keeper keeps tap alive)
  -> shouldSmoothAny == true -> return nil (original event consumed)
  -> tryStart() silently fails (poster nil/invalid, return value unchecked)
  -> processing() callback never fires -> smooth events never posted
  -> Result: event swallowed, no replacement -> total scroll failure
```

### Additional Trigger: Display-Only Sleep

Screen timeout (Energy Saver "Turn display off after X minutes") does NOT trigger `willSleepNotification`/`didWakeNotification`, but CVDisplayLink depends on VSync which stops when display sleeps. Current code has zero handling for this scenario.

---

## Part 1: CVDisplayLink Recovery Fix

### Files Changed

| File | Scope |
|------|-------|
| `Mos/ScrollCore/ScrollPoster.swift` | Core changes: create error handling, tryStart failure recovery, keeper timer, isAvailable, zombie detection |
| `Mos/ScrollCore/ScrollCore.swift` | 1 line: fallback passthrough in scrollEventCallBack |
| `Mos/AppDelegate.swift` | 1 observer: didChangeScreenParametersNotification with debounced recreate |

### Design Decisions

#### Thread Safety: Main Thread Serialization (No New Locks)

- `scrollEventCallBack` runs on main thread (Interceptor adds source to main RunLoop)
- `keeper` timer runs on main thread
- `create()` / `recreateDisplayLink()` called from `enable()` or keeper timer -> main thread
- `tryStart()` called from `scrollEventCallBack` chain -> main thread
- `poster` writes only on main thread, reads primarily on main thread
- Only cross-thread access: `stop()` from CVDisplayLink thread reads `poster` -> but `create()` calls `CVDisplayLinkStop(old)` first, Apple docs guarantee callback won't fire after stop returns
- `lastCallbackTime`: written in `processing()` (CVDisplayLink thread), read in `healthCheck()` (main thread) -> protected by existing `stateLock`
- **Conclusion: no additional locks needed for `poster`**

#### Three-Layer Recovery (Passive + Active + Fallback)

1. **Passive**: `tryStart()` detects poster nil/start failure -> immediate `recreateDisplayLink()` with 3-second cooldown
2. **Active**: `NSApplication.didChangeScreenParametersNotification` -> debounced 1-second delay -> `recreateDisplayLink()` (covers hot-plug, display sleep/wake, resolution changes)
3. **Fallback**: keeper timer every 5 seconds + `lastCallbackTime` zombie detection (running=true but callback silent >2 seconds)

#### Graceful Degradation

When CVDisplayLink is unavailable, `scrollEventCallBack` passes through the original event instead of consuming it. User gets raw (non-smooth) scrolling, which is far better than total scroll failure.

### Detailed Changes

#### ScrollPoster.swift

**New properties:**
```swift
private var keeper: Timer?
private var lastCallbackTime: CFTimeInterval = 0.0
private var lastRecreateAttempt: CFTimeInterval = 0.0
private let recreateCooldown: CFTimeInterval = 3.0

// Main thread only, no lock needed
var isAvailable: Bool { return poster != nil }
```

**create() rewrite:**
```swift
func create() {
    // Clean up old CVDisplayLink before creating new one
    if let old = poster {
        if CVDisplayLinkIsRunning(old) {
            CVDisplayLinkStop(old)  // Synchronous: waits for callback to finish
        }
        poster = nil
    }
    var newPoster: CVDisplayLink?
    let result = CVDisplayLinkCreateWithActiveCGDisplays(&newPoster)
    if result == kCVReturnSuccess, let valid = newPoster {
        CVDisplayLinkSetOutputCallback(valid, { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
            ScrollPoster.shared.processing()
            return kCVReturnSuccess
        }, nil)
        poster = valid
    } else {
        poster = nil
        NSLog("ScrollPoster: CVDisplayLink creation failed (%d)", result)
    }
}
```

**tryStart() rewrite:**
```swift
func tryStart() {
    guard let validPoster = poster else {
        if !recreateDisplayLink() {
            // Cooldown rejected recreate; clear stale buffer to prevent
            // scroll jump when poster eventually recovers
            reset()
        }
        return
    }
    if !CVDisplayLinkIsRunning(validPoster) {
        let result = CVDisplayLinkStart(validPoster)
        if result == kCVReturnSuccess {
            // Give keeper a grace period so it doesn't misidentify
            // a freshly started poster as zombie
            os_unfair_lock_lock(&stateLock)
            lastCallbackTime = CFAbsoluteTimeGetCurrent()
            os_unfair_lock_unlock(&stateLock)
        } else {
            let _ = recreateDisplayLink()
        }
    }
}
```

**recreateDisplayLink() with cooldown:**
```swift
@discardableResult
func recreateDisplayLink() -> Bool {
    let now = CFAbsoluteTimeGetCurrent()
    guard now - lastRecreateAttempt >= recreateCooldown else { return false }
    lastRecreateAttempt = now
    create()
    if let validPoster = poster {
        let result = CVDisplayLinkStart(validPoster)
        if result == kCVReturnSuccess {
            os_unfair_lock_lock(&stateLock)
            lastCallbackTime = CFAbsoluteTimeGetCurrent()
            os_unfair_lock_unlock(&stateLock)
        } else {
            NSLog("ScrollPoster: CVDisplayLink start failed after recreate (%d)", result)
        }
    }
    return true
}
```

**Keeper timer:**
```swift
func startKeeper() {
    keeper?.invalidate()
    keeper = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
        self?.healthCheck()
    }
}

func stopKeeper() {
    keeper?.invalidate()
    keeper = nil
}

private func healthCheck() {
    guard let validPoster = poster else {
        recreateDisplayLink()
        return
    }
    if CVDisplayLinkIsRunning(validPoster) {
        os_unfair_lock_lock(&stateLock)
        let lastTime = lastCallbackTime
        os_unfair_lock_unlock(&stateLock)
        // lastTime > 0 avoids false positive before first callback fires
        if lastTime > 0 && CFAbsoluteTimeGetCurrent() - lastTime > 2.0 {
            NSLog("ScrollPoster: zombie CVDisplayLink detected, recreating")
            recreateDisplayLink()
        }
    }
}
```

**processing() addition (at the top, inside existing lock):**
```swift
func processing() {
    // ... existing os_unfair_lock_lock(&stateLock) ...
    lastCallbackTime = CFAbsoluteTimeGetCurrent()
    // ... rest of existing logic unchanged ...
}
```

**Lifecycle integration:**
- `ScrollCore.enable()` calls `ScrollPoster.shared.startKeeper()` after `create()`
- `ScrollCore.disable()` calls `ScrollPoster.shared.stopKeeper()` after `stop()`

#### ScrollCore.swift

**scrollEventCallBack change (1 line):**

Replace:
```swift
if shouldSmoothAny {
    return nil
}
```

With:
```swift
if shouldSmoothAny {
    if ScrollPoster.shared.isAvailable {
        return nil
    } else {
        return Unmanaged.passUnretained(event)  // Graceful degradation
    }
}
```

#### AppDelegate.swift

**Add in applicationWillFinishLaunching, after existing notification registrations:**
```swift
// Debounce timer for screen parameter changes
private var screenChangeTimer: Timer?

// In applicationWillFinishLaunching:
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil, queue: .main
) { [weak self] _ in
    self?.screenChangeTimer?.invalidate()
    self?.screenChangeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
        ScrollPoster.shared.recreateDisplayLink()
    }
}
```

### Edge Cases Covered

| Scenario | Recovery Path | Max Latency |
|----------|--------------|-------------|
| System sleep/wake (display not ready at didWake) | enable() -> create() fails -> tryStart() recreate -> OR keeper 5s healthCheck | ~3-8s |
| Display-only sleep (screen timeout) | didChangeScreenParameters + keeper zombie detection | ~1-6s |
| External display hot-unplug | didChangeScreenParameters 1s delay -> recreate | ~1s |
| Multi-display: VSync source removed | keeper zombie detection (running but no callbacks) | ~5-7s |
| Clamshell mode: unplug external | didChangeScreenParameters -> recreate with remaining display | ~1s |
| Rapid scroll during CVDisplayLink unavailable | fallback passthrough (raw scroll, no smooth) | 0ms |
| create() fails during cooldown period | reset() clears buffer; keeper retries after cooldown | 3-5s |

---

## Part 2: XCTest Infrastructure & Test Suites

### Infrastructure

- New `MosTests` XCTest target added to `Mos.xcodeproj`
- `@testable import Mos` for internal type access
- Debug build configuration (ensures `#if DEBUG` diagnostics are visible)
- `XCTSkipUnless` for CGEvent-dependent tests in headless CI

### Small Refactors to Enable Testing (Behavior-Preserving)

| Change | Purpose |
|--------|---------|
| `ScrollDispatchContext.init()` -> `internal` (remove `private`) | Allow test instances for isolation |
| Add `#if DEBUG` `resetDiagnostics()` on ScrollDispatchContext | Reset counters between tests |
| Add `#if DEBUG` `internal var eventTTL` on ScrollDispatchContext | Inject short TTL for timeout tests |
| Add `bindingsProvider` closure on MosInputProcessor | Inject test bindings without touching UserDefaults |
| Extract `ScrollCore.makeScrollDecision(...)` static pure function | Test smooth/reverse/passthrough decision matrix without CGEventTap |

### Test Suites

#### P0: Suite 1 - ScrollPhaseTests

Full state machine coverage. Parameterized matrix: each of 5 event methods x all 9 states.

Key scenarios:
- Idle -> TrackingBegin (separated input)
- TrackingOngoing -> TrackingEnd (manual input ended)
- TrackingEnd -> MomentumBegin -> MomentumOngoing -> MomentumEnd -> Idle (full inertial)
- MomentumOngoing interrupted by new input -> MomentumEnd + TrackingBegin
- Non-inertial: Tracking -> TrackingEnd (no Momentum)
- didDeliverFrame autoAdvance mechanism
- All "empty plan" defensive cases (calling methods from unexpected states)
- apply() direct phase setting for Hold/Leave

#### P0: Suite 2 - ScrollDispatchContextTests

Test with independent instances (non-singleton) for isolation.

- capture stores template; preparePostingSnapshot returns valid clone
- capture failure (nil event clone) returns false
- advanceGeneration invalidates old-generation snapshots in enqueue
- clearContext makes preparePostingSnapshot return nil
- invalidateAll clears everything
- TTL expiry (inject short eventTTL, verify droppedFramesByTTL counter)
- Concurrent capture + preparePostingSnapshot stress test (DispatchQueue, not concurrentPerform)
- advanceGeneration + enqueue concurrent safety

#### P1: Suite 3 - ScrollEventTests

Requires CGEvent construction (`XCTSkipUnless`).

- Parse vertical/horizontal scroll from CGEvent fields
- **usableValue priority: scrollPt > scrollFixPt > scrollFix** (3 test cases for each fallback level)
- reverseY / reverseX negate values correctly
- normalizeY/X: below step -> normalize to step; above step -> preserve; positive vs negative direction
- clearY / clearX zero out values
- Both axes present simultaneously

#### P1: Suite 4 - InterpolatorTests + ScrollFilterTests

Pure math, no dependencies.

Interpolator:
- lerp: zero distance, full transition, half transition, negative values, trans > 1.0
- smoothStep2/3: boundary values, division by zero when dest=0

ScrollFilter:
- Initial value (0,0)
- Single fill -> verify window state (array[1] is pivot, not array[0])
- Multiple fills -> curve smoothing convergence
- Reset clears state
- Direction change transition behavior

#### P1: Suite 5 - ScrollCoreHotkeyTests

Test `handleScrollHotkeyFromHIDPlusPlus` (pure logic, no CGEventTap dependency).

- key-down matches dash hotkey -> dashScroll=true, dashAmplification=5.0
- key-down matches toggle hotkey -> toggleScroll=true
- key-down matches block hotkey -> blockSmooth=true
- key-up clears state by tracked code (not current app config)
- Multiple hotkeys simultaneously active
- key-up with different code than tracked -> no clear
- Application context refresh on key-down

#### P2: Suite 6 - ScrollPosterStateTests

No CVDisplayLink involvement.

- shift(): no shifting, vertical-to-horizontal, already horizontal, MXMaster normalization (both axes), both axes with shifting=true (doesn't swap)
- update() direction: same direction accumulates buffer; reverse direction resets buffer
- brake(): buffer = current

#### P2: Suite 7 - RecordedEventMatchTests

- Exact match (type + code + modifiers)
- Modifier mismatch -> false
- Code mismatch -> false
- DeviceFilter nil -> matches any device
- DeviceFilter vendor-only (productId=nil) -> wildcard product
- DeviceFilter full match (vendor + product)
- DeviceFilter present but event device=nil -> false
- Keyboard event phase=up -> does not match
- Equality operator doesn't compare deviceFilter (document behavior)

#### P2: Suite 8 - ScrollHotkeyTests

- isModifierKey for command/control/option/shift codes -> true
- Non-modifier key -> false
- matches() keyboard event
- matches() mouse button event
- modifierMask maps to correct CGEventFlags
- legacyCode Int migration to ScrollHotkey

#### P3: Suite 9 - MosInputProcessorTests

Uses injected bindingsProvider.

- Matching binding exists -> consumed
- No matching binding -> passthrough
- Disabled binding -> passthrough
- Multiple bindings, first match wins

#### P3: Suite 10 - MosInputEventTests

- CGEvent keyDown -> MosInputEvent type=keyboard
- CGEvent otherMouseDown -> MosInputEvent type=mouse
- Modifier flag extraction accuracy
- displayComponents formatting

#### P3: Suite 11 - ButtonFilterTests

- Unblocked app passes through
- Blocked app filters event
- Add/remove blocked app dynamically

#### P2: Suite 12 - ScrollDecisionTests

Tests extracted `makeScrollDecision()` pure function.

- Global smooth enabled, no exceptions -> smooth both axes
- Per-app exception with inherit=false -> use app-specific settings
- Allowlist mode: unlisted app -> no smooth/reverse
- blockSmooth hotkey active -> disable smooth
- toggleScroll active -> shift vertical to horizontal
- Launchpad active -> force disable smooth
- Reverse vertical + horizontal independently
- Combined: reverse + smooth + per-app + shift

### Implementation Priority

```
Phase 1 (P0): ScrollPhaseTests, ScrollDispatchContextTests
Phase 2 (P1): ScrollEventTests, InterpolatorTests, ScrollFilterTests, ScrollCoreHotkeyTests
Phase 3 (P2): ScrollPosterStateTests, RecordedEventMatchTests, ScrollHotkeyTests, ScrollDecisionTests
Phase 4 (P3): MosInputProcessorTests, MosInputEventTests, ButtonFilterTests
```
