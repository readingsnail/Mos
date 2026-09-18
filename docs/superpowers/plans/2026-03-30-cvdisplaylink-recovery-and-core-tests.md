# CVDisplayLink Recovery & Core Event Processing Tests — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix scroll failure after macOS sleep/wake by adding CVDisplayLink recovery + graceful degradation, then add XCTest coverage for all core event processing logic.

**Architecture:** Three-layer CVDisplayLink recovery (passive recreate in tryStart, active via screen-change notification, fallback via keeper timer with zombie detection). Graceful degradation passes through raw events when CVDisplayLink unavailable. XCTest target tests all pure logic (Interpolator, ScrollFilter, ScrollPhase state machine, ScrollEvent parsing, hotkey matching) without requiring system permissions.

**Tech Stack:** Swift 4.0+, macOS 10.13+, XCTest, CoreVideo (CVDisplayLink), CoreGraphics (CGEvent)

**Build command:** `xcodebuild build -scheme Debug -project Mos.xcodeproj -quiet`
**Test command:** `xcodebuild test -scheme Debug -project Mos.xcodeproj -quiet`

---

## File Structure

### Modified Files
| File | Changes |
|------|---------|
| `Mos/ScrollCore/ScrollPoster.swift` | Add recovery properties, rewrite create/tryStart, add keeper timer + healthCheck + recreateDisplayLink |
| `Mos/ScrollCore/ScrollCore.swift:178-179` | Add isAvailable fallback check |
| `Mos/ScrollCore/ScrollCore.swift:349-350` | Add startKeeper after create |
| `Mos/ScrollCore/ScrollCore.swift:360-361` | Add stopKeeper after stop |
| `Mos/AppDelegate.swift` | Add screenChangeTimer property + didChangeScreenParameters observer |
| `Mos/ScrollCore/ScrollDispatchContext.swift:34,44` | Make eventTTL var + init internal (DEBUG only) |

### New Files
| File | Purpose |
|------|---------|
| `MosTests/ScrollPhaseTests.swift` | State machine transition matrix tests |
| `MosTests/InterpolatorTests.swift` | Interpolation math tests |
| `MosTests/ScrollFilterTests.swift` | Curve smoothing filter tests |
| `MosTests/ScrollEventTests.swift` | Event parsing + reverse/normalize/clear tests |
| `MosTests/ScrollDispatchContextTests.swift` | Generation, TTL, concurrent safety tests |
| `MosTests/ScrollCoreHotkeyTests.swift` | HID++ hotkey matching tests |
| `MosTests/ScrollPosterStateTests.swift` | shift/update direction tests |
| `MosTests/ScrollHotkeyTests.swift` | ScrollHotkey matching + modifier tests |

---

## Part 1: CVDisplayLink Recovery Fix

### Task 1: ScrollPoster — Recovery Properties + create() Rewrite

**Files:**
- Modify: `Mos/ScrollCore/ScrollPoster.swift:12-44` (properties), `Mos/ScrollCore/ScrollPoster.swift:148-159` (create), `Mos/ScrollCore/ScrollPoster.swift:252-254` (processing)

- [ ] **Step 1: Add recovery properties to ScrollPoster**

In `Mos/ScrollCore/ScrollPoster.swift`, after line 43 (`private let dispatchContext = ScrollDispatchContext.shared`), add:

```swift
    // CVDisplayLink 恢复机制
    private var keeper: Timer?
    private var lastCallbackTime: CFTimeInterval = 0.0
    private var lastRecreateAttempt: CFTimeInterval = 0.0
    private let recreateCooldown: CFTimeInterval = 3.0
    // 主线程访问, 无需锁
    var isAvailable: Bool { return poster != nil }
```

- [ ] **Step 2: Rewrite create() with error handling and old object cleanup**

Replace the entire `create()` method (lines 150-158) with:

```swift
    // 初始化 CVDisplayLink
    func create() {
        // 清理旧的 CVDisplayLink
        if let old = poster {
            if CVDisplayLinkIsRunning(old) {
                CVDisplayLinkStop(old)
            }
            poster = nil
        }
        // 创建新的 CVDisplayLink, 检查返回值
        var newPoster: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&newPoster)
        if result == kCVReturnSuccess, let validPoster = newPoster {
            CVDisplayLinkSetOutputCallback(validPoster, { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
                ScrollPoster.shared.processing()
                return kCVReturnSuccess
            }, nil)
            poster = validPoster
        } else {
            poster = nil
            NSLog("ScrollPoster: CVDisplayLink creation failed (%d)", result)
        }
    }
```

- [ ] **Step 3: Add lastCallbackTime update in processing()**

In `processing()` (line 254), after the existing `os_unfair_lock_lock(&stateLock)`, add one line:

```swift
        lastCallbackTime = CFAbsoluteTimeGetCurrent()
```

So lines 253-255 become:

```swift
        var pendingStopPhase: Phase?
        os_unfair_lock_lock(&stateLock)
        lastCallbackTime = CFAbsoluteTimeGetCurrent()
        // 计算插值
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme Debug -project Mos.xcodeproj -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Mos/ScrollCore/ScrollPoster.swift
git commit -m "fix(scroll-poster): add recovery properties and rewrite create() with error handling"
```

---

### Task 2: ScrollPoster — tryStart/recreateDisplayLink/keeper

**Files:**
- Modify: `Mos/ScrollCore/ScrollPoster.swift:161-167` (tryStart), add recreateDisplayLink/keeper/healthCheck methods

- [ ] **Step 1: Rewrite tryStart() with failure recovery**

Replace `tryStart()` (lines 161-167) with:

```swift
    // 启动事件发送器
    func tryStart() {
        guard let validPoster = poster else {
            if !recreateDisplayLink() {
                // cooldown 拒绝了重建; 清理陈旧 buffer 防止恢复后滚动跳变
                reset()
            }
            return
        }
        if !CVDisplayLinkIsRunning(validPoster) {
            let result = CVDisplayLinkStart(validPoster)
            if result == kCVReturnSuccess {
                // 给 keeper 一个宽限期, 防止误判新启动的 poster 为僵尸
                os_unfair_lock_lock(&stateLock)
                lastCallbackTime = CFAbsoluteTimeGetCurrent()
                os_unfair_lock_unlock(&stateLock)
            } else {
                let _ = recreateDisplayLink()
            }
        }
    }
```

- [ ] **Step 2: Add recreateDisplayLink() with cooldown**

After the `stop()` method's closing brace (after line 221), add:

```swift
    // 重建 CVDisplayLink (带冷却期)
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

- [ ] **Step 3: Add keeper timer and healthCheck**

After `recreateDisplayLink()`, add:

```swift
    // 守护定时器 (与 Interceptor 的 keeper 模式一致)
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
            // lastTime > 0 避免首次回调前误判
            if lastTime > 0 && CFAbsoluteTimeGetCurrent() - lastTime > 2.0 {
                NSLog("ScrollPoster: zombie CVDisplayLink detected, recreating")
                recreateDisplayLink()
            }
        }
    }
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme Debug -project Mos.xcodeproj -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Mos/ScrollCore/ScrollPoster.swift
git commit -m "fix(scroll-poster): add tryStart recovery, recreateDisplayLink with cooldown, keeper timer with zombie detection"
```

---

### Task 3: ScrollCore Fallback + AppDelegate Notification + Lifecycle

**Files:**
- Modify: `Mos/ScrollCore/ScrollCore.swift:178-179,349,360`
- Modify: `Mos/AppDelegate.swift`

- [ ] **Step 1: Add graceful degradation in scrollEventCallBack**

In `Mos/ScrollCore/ScrollCore.swift`, replace lines 178-179:

```swift
        if shouldSmoothAny {
            return nil
```

With:

```swift
        if shouldSmoothAny {
            if ScrollPoster.shared.isAvailable {
                return nil
            } else {
                return Unmanaged.passUnretained(event)
            }
```

- [ ] **Step 2: Add keeper lifecycle in enable()/disable()**

In `enable()`, after line 349 (`ScrollPoster.shared.create()`), add:

```swift
            ScrollPoster.shared.startKeeper()
```

In `disable()`, after line 360 (`ScrollPoster.shared.stop()`), add:

```swift
        ScrollPoster.shared.stopKeeper()
```

- [ ] **Step 3: Add screenChangeTimer property in AppDelegate**

In `Mos/AppDelegate.swift`, after line 12 (`class AppDelegate: NSObject, NSApplicationDelegate {`), add:

```swift
    // 防抖定时器: 显示器参数变化通知
    private var screenChangeTimer: Timer?
```

- [ ] **Step 4: Add didChangeScreenParameters observer**

In `applicationWillFinishLaunching`, after line 55 (the last `addObserver` call), add:

```swift
        // 监听显示器参数变化 (热插拔/分辨率/显示器休眠唤醒), 延迟重建 CVDisplayLink
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

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild build -scheme Debug -project Mos.xcodeproj -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Mos/ScrollCore/ScrollCore.swift Mos/AppDelegate.swift
git commit -m "fix(scroll): add graceful degradation fallback and screen-change notification recovery"
```

---

## Part 2: XCTest Infrastructure & Test Suites

### Task 4: Create MosTests XCTest Target + Testability Refactors

**Files:**
- Create: `MosTests/` directory and XCTest target via Xcode CLI
- Modify: `Mos/ScrollCore/ScrollDispatchContext.swift:34,44`

- [ ] **Step 1: Create MosTests directory**

```bash
mkdir -p MosTests
```

- [ ] **Step 2: Add XCTest unit test target via Ruby script**

Create a Ruby script that patches the Xcode project to add a test target. This is needed because `xcodebuild` cannot create targets.

```bash
cat > /tmp/add_test_target.rb << 'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('Mos.xcodeproj')

# Don't add if already exists
if project.targets.any? { |t| t.name == 'MosTests' }
  puts "MosTests target already exists"
  exit 0
end

main_target = project.targets.find { |t| t.name == 'Mos' }

test_target = project.new_target(:unit_test_bundle, 'MosTests', :osx)
test_target.build_configurations.each do |config|
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '10.13'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'me.caldis.MosTests'
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Mos Debug.app/Contents/MacOS/Mos Debug'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  config.build_settings['INFOPLIST_FILE'] = ''
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
end
test_target.add_dependency(main_target)

group = project.main_group.find_subpath('MosTests', true)
group.set_source_tree('SOURCE_ROOT')
group.set_path('MosTests')

# Add test scheme support
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(main_target, test_target)
scheme.save_as(project.path, 'Debug')

project.save
puts "MosTests target added successfully"
RUBY
gem list xcodeproj -i > /dev/null 2>&1 || gem install xcodeproj --no-document
ruby /tmp/add_test_target.rb
```

- [ ] **Step 3: Make ScrollDispatchContext testable**

In `Mos/ScrollCore/ScrollDispatchContext.swift`, change line 34 from:

```swift
    private let eventTTL: CFTimeInterval = 5.0
```

To:

```swift
#if DEBUG
    var eventTTL: CFTimeInterval = 5.0
#else
    private let eventTTL: CFTimeInterval = 5.0
#endif
```

Change line 44 from:

```swift
    private init() {}
```

To:

```swift
#if DEBUG
    init() {}
#else
    private init() {}
#endif
```

Add after `diagnosticsSnapshot()` (before the final `#endif` on line 151):

```swift

    func resetDiagnostics() {
        os_unfair_lock_lock(&lock)
        postedFrames = 0
        droppedFramesByGeneration = 0
        droppedFramesByTTL = 0
        skippedSyntheticEvents = 0
        updateSnapshotFailures = 0
        os_unfair_lock_unlock(&lock)
    }
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme Debug -project Mos.xcodeproj -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Mos.xcodeproj MosTests Mos/ScrollCore/ScrollDispatchContext.swift
git commit -m "test: add MosTests XCTest target and ScrollDispatchContext testability refactors"
```

---

### Task 5: ScrollPhaseTests (P0)

**Files:**
- Create: `MosTests/ScrollPhaseTests.swift`

- [ ] **Step 1: Write ScrollPhaseTests**

```swift
import XCTest
@testable import Mos

final class ScrollPhaseTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ScrollPhase.shared.reset()
    }

    // MARK: - 初始状态

    func test_initial_state_is_idle() {
        XCTAssertEqual(ScrollPhase.shared.phase, .Idle)
    }

    // MARK: - onManualInputDetected

    func test_separated_input_from_idle_starts_tracking() {
        let plan = ScrollPhase.shared.onManualInputDetected(isSeparated: true)
        XCTAssertEqual(plan.queue.count, 1)
        XCTAssertEqual(plan.queue[0].0, .TrackingBegin)
        XCTAssertEqual(plan.queue[0].1, .TrackingOngoing)
        XCTAssertNil(plan.target)
    }

    func test_non_separated_input_from_idle_starts_tracking() {
        let plan = ScrollPhase.shared.onManualInputDetected(isSeparated: false)
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingBegin)
        XCTAssertEqual(plan.target?.1, .TrackingOngoing)
    }

    func test_continuous_input_continues_tracking() {
        ScrollPhase.shared.apply(phase: .TrackingOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onManualInputDetected(isSeparated: false)
        XCTAssertEqual(plan.target?.0, .TrackingOngoing)
    }

    func test_separated_input_during_momentum_interrupts() {
        ScrollPhase.shared.apply(phase: .MomentumOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onManualInputDetected(isSeparated: true)
        // 应先补发 MomentumEnd, 再 TrackingBegin
        XCTAssertEqual(plan.queue.count, 2)
        XCTAssertEqual(plan.queue[0].0, .MomentumEnd)
        XCTAssertEqual(plan.queue[1].0, .TrackingBegin)
        XCTAssertNil(plan.target)
    }

    func test_non_separated_input_during_momentum_interrupts() {
        ScrollPhase.shared.apply(phase: .MomentumOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onManualInputDetected(isSeparated: false)
        XCTAssertEqual(plan.queue.count, 1)
        XCTAssertEqual(plan.queue[0].0, .MomentumEnd)
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingBegin)
    }

    func test_input_during_momentum_begin() {
        ScrollPhase.shared.apply(phase: .MomentumBegin, autoAdvance: nil)
        let plan = ScrollPhase.shared.onManualInputDetected(isSeparated: true)
        XCTAssertEqual(plan.queue[0].0, .MomentumEnd)
    }

    // MARK: - onManualInputEnded

    func test_manual_input_ended_from_tracking_ongoing() {
        ScrollPhase.shared.apply(phase: .TrackingOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onManualInputEnded()
        XCTAssertEqual(plan.target?.0, .TrackingEnd)
    }

    func test_manual_input_ended_from_tracking_begin() {
        ScrollPhase.shared.apply(phase: .TrackingBegin, autoAdvance: nil)
        let plan = ScrollPhase.shared.onManualInputEnded()
        XCTAssertEqual(plan.target?.0, .TrackingEnd)
    }

    func test_manual_input_ended_from_idle_is_noop() {
        let plan = ScrollPhase.shared.onManualInputEnded()
        XCTAssertTrue(plan.queue.isEmpty)
        XCTAssertNil(plan.target)
    }

    func test_manual_input_ended_from_momentum_is_noop() {
        ScrollPhase.shared.apply(phase: .MomentumOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onManualInputEnded()
        XCTAssertTrue(plan.queue.isEmpty)
        XCTAssertNil(plan.target)
    }

    // MARK: - onMomentumStart

    func test_momentum_start_from_tracking_end() {
        ScrollPhase.shared.apply(phase: .TrackingEnd, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumStart()
        XCTAssertEqual(plan.target?.0, .MomentumBegin)
        XCTAssertEqual(plan.target?.1, .MomentumOngoing)
    }

    func test_momentum_start_from_momentum_end() {
        ScrollPhase.shared.apply(phase: .MomentumEnd, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumStart()
        XCTAssertEqual(plan.target?.0, .MomentumBegin)
    }

    func test_momentum_start_from_momentum_begin_advances() {
        ScrollPhase.shared.apply(phase: .MomentumBegin, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumStart()
        XCTAssertEqual(plan.target?.0, .MomentumOngoing)
    }

    func test_momentum_start_from_idle_is_noop() {
        let plan = ScrollPhase.shared.onMomentumStart()
        XCTAssertTrue(plan.queue.isEmpty)
        XCTAssertNil(plan.target)
    }

    func test_momentum_start_from_tracking_ongoing_is_noop() {
        ScrollPhase.shared.apply(phase: .TrackingOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumStart()
        XCTAssertNil(plan.target)
    }

    // MARK: - onMomentumOngoing

    func test_momentum_ongoing_from_momentum_begin() {
        ScrollPhase.shared.apply(phase: .MomentumBegin, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumOngoing()
        XCTAssertEqual(plan.target?.0, .MomentumOngoing)
    }

    func test_momentum_ongoing_from_momentum_ongoing_is_noop() {
        ScrollPhase.shared.apply(phase: .MomentumOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumOngoing()
        XCTAssertNil(plan.target)
    }

    // MARK: - onMomentumFinish

    func test_momentum_finish_from_momentum_ongoing() {
        ScrollPhase.shared.apply(phase: .MomentumOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumFinish()
        XCTAssertEqual(plan.target?.0, .MomentumEnd)
        XCTAssertEqual(plan.target?.1, .Idle)
    }

    func test_momentum_finish_from_tracking_ongoing() {
        ScrollPhase.shared.apply(phase: .TrackingOngoing, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumFinish()
        XCTAssertEqual(plan.target?.0, .TrackingEnd)
        XCTAssertEqual(plan.target?.1, .Idle)
    }

    func test_momentum_finish_from_tracking_begin() {
        ScrollPhase.shared.apply(phase: .TrackingBegin, autoAdvance: nil)
        let plan = ScrollPhase.shared.onMomentumFinish()
        XCTAssertEqual(plan.target?.0, .TrackingEnd)
        XCTAssertEqual(plan.target?.1, .Idle)
    }

    func test_momentum_finish_from_idle_is_noop() {
        let plan = ScrollPhase.shared.onMomentumFinish()
        XCTAssertTrue(plan.queue.isEmpty)
        XCTAssertNil(plan.target)
    }

    // MARK: - didDeliverFrame

    func test_did_deliver_frame_auto_advance() {
        ScrollPhase.shared.apply(phase: .TrackingBegin, autoAdvance: .TrackingOngoing)
        XCTAssertEqual(ScrollPhase.shared.phase, .TrackingBegin)
        ScrollPhase.shared.didDeliverFrame()
        XCTAssertEqual(ScrollPhase.shared.phase, .TrackingOngoing)
    }

    func test_did_deliver_frame_no_advance() {
        ScrollPhase.shared.apply(phase: .TrackingOngoing, autoAdvance: nil)
        ScrollPhase.shared.didDeliverFrame()
        XCTAssertEqual(ScrollPhase.shared.phase, .TrackingOngoing)
    }

    // MARK: - 完整序列

    func test_full_inertial_scroll_sequence() {
        // 1. Idle -> TrackingBegin
        var plan = ScrollPhase.shared.onManualInputDetected(isSeparated: true)
        ScrollPhase.shared.apply(phase: plan.queue[0].0, autoAdvance: plan.queue[0].1)
        XCTAssertEqual(ScrollPhase.shared.phase, .TrackingBegin)

        // 2. didDeliverFrame -> TrackingOngoing
        ScrollPhase.shared.didDeliverFrame()
        XCTAssertEqual(ScrollPhase.shared.phase, .TrackingOngoing)

        // 3. TrackingOngoing -> TrackingEnd
        plan = ScrollPhase.shared.onManualInputEnded()
        ScrollPhase.shared.apply(phase: plan.target!.0, autoAdvance: plan.target!.1)
        XCTAssertEqual(ScrollPhase.shared.phase, .TrackingEnd)

        // 4. TrackingEnd -> MomentumBegin
        plan = ScrollPhase.shared.onMomentumStart()
        ScrollPhase.shared.apply(phase: plan.target!.0, autoAdvance: plan.target!.1)
        XCTAssertEqual(ScrollPhase.shared.phase, .MomentumBegin)

        // 5. MomentumBegin -> MomentumOngoing
        ScrollPhase.shared.didDeliverFrame()
        XCTAssertEqual(ScrollPhase.shared.phase, .MomentumOngoing)

        // 6. MomentumOngoing -> MomentumEnd -> Idle
        plan = ScrollPhase.shared.onMomentumFinish()
        ScrollPhase.shared.apply(phase: plan.target!.0, autoAdvance: plan.target!.1)
        XCTAssertEqual(ScrollPhase.shared.phase, .MomentumEnd)
        ScrollPhase.shared.didDeliverFrame()
        XCTAssertEqual(ScrollPhase.shared.phase, .Idle)
    }
}
```

- [ ] **Step 2: Add file to Xcode project and run tests**

```bash
ruby -e "
require 'xcodeproj'
project = Xcodeproj::Project.open('Mos.xcodeproj')
target = project.targets.find { |t| t.name == 'MosTests' }
group = project.main_group.find_subpath('MosTests', true)
ref = group.new_file('MosTests/ScrollPhaseTests.swift')
target.add_file_references([ref])
project.save
"
xcodebuild test -scheme Debug -project Mos.xcodeproj -only-testing:MosTests/ScrollPhaseTests -quiet 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MosTests/ScrollPhaseTests.swift Mos.xcodeproj
git commit -m "test: add ScrollPhaseTests covering state machine transitions"
```

---

### Task 6: InterpolatorTests + ScrollFilterTests (P1)

**Files:**
- Create: `MosTests/InterpolatorTests.swift`
- Create: `MosTests/ScrollFilterTests.swift`

- [ ] **Step 1: Write InterpolatorTests**

```swift
import XCTest
@testable import Mos

final class InterpolatorTests: XCTestCase {

    func test_lerp_zero_distance() {
        let result = Interpolator.lerp(src: 5.0, dest: 5.0, trans: 0.5)
        XCTAssertEqual(result, 0.0, accuracy: 1e-10)
    }

    func test_lerp_full_transition() {
        let result = Interpolator.lerp(src: 0.0, dest: 10.0, trans: 1.0)
        XCTAssertEqual(result, 10.0, accuracy: 1e-10)
    }

    func test_lerp_half_transition() {
        let result = Interpolator.lerp(src: 0.0, dest: 10.0, trans: 0.5)
        XCTAssertEqual(result, 5.0, accuracy: 1e-10)
    }

    func test_lerp_negative_direction() {
        let result = Interpolator.lerp(src: 10.0, dest: 0.0, trans: 0.5)
        XCTAssertEqual(result, -5.0, accuracy: 1e-10)
    }

    func test_lerp_trans_beyond_one() {
        let result = Interpolator.lerp(src: 0.0, dest: 10.0, trans: 2.0)
        XCTAssertEqual(result, 20.0, accuracy: 1e-10)
    }

    func test_lerp_negative_values() {
        let result = Interpolator.lerp(src: -10.0, dest: -20.0, trans: 0.5)
        XCTAssertEqual(result, -5.0, accuracy: 1e-10)
    }
}
```

- [ ] **Step 2: Write ScrollFilterTests**

```swift
import XCTest
@testable import Mos

final class ScrollFilterTests: XCTestCase {

    func test_initial_value_is_zero() {
        let filter = ScrollFilter()
        let v = filter.value()
        XCTAssertEqual(v.y, 0.0)
        XCTAssertEqual(v.x, 0.0)
    }

    func test_fill_single_value() {
        let filter = ScrollFilter()
        let result = filter.fill(with: (y: 10.0, x: 5.0))
        // polish uses array[1] as pivot (initially 0.0)
        // diff = 10.0 - 0.0 = 10.0
        // result array = [0.0, 0.23*10, 0.5*10, 0.77*10, 10.0]
        // value() returns array[0] = 0.0 (the previous array[1])
        XCTAssertEqual(result.y, 0.0, accuracy: 1e-10)
        XCTAssertEqual(result.x, 0.0, accuracy: 1e-10)
    }

    func test_fill_second_value_uses_pivot() {
        let filter = ScrollFilter()
        _ = filter.fill(with: (y: 10.0, x: 0.0))
        // After first fill, curveWindowY = [0.0, 2.3, 5.0, 7.7, 10.0]
        // Second fill: pivot = array[1] = 2.3
        let result = filter.fill(with: (y: 10.0, x: 0.0))
        XCTAssertEqual(result.y, 2.3, accuracy: 1e-10)
    }

    func test_reset_clears_state() {
        let filter = ScrollFilter()
        _ = filter.fill(with: (y: 100.0, x: 50.0))
        filter.reset()
        let v = filter.value()
        XCTAssertEqual(v.y, 0.0)
        XCTAssertEqual(v.x, 0.0)
    }

    func test_direction_change_smoothing() {
        let filter = ScrollFilter()
        _ = filter.fill(with: (y: 10.0, x: 0.0))
        _ = filter.fill(with: (y: 10.0, x: 0.0))
        // Now fill with negative direction
        let result = filter.fill(with: (y: -10.0, x: 0.0))
        // pivot is curveWindowY[1] from previous fill
        // The output should be transitioning, not jumping to -10
        XCTAssertTrue(result.y > -10.0, "Direction change should be smoothed")
    }

    func test_convergence_over_multiple_fills() {
        let filter = ScrollFilter()
        var lastY = 0.0
        // Repeatedly fill with same value, should converge toward it
        for _ in 0..<20 {
            let result = filter.fill(with: (y: 5.0, x: 0.0))
            lastY = result.y
        }
        XCTAssertEqual(lastY, 5.0, accuracy: 0.01)
    }
}
```

- [ ] **Step 3: Add files to Xcode project and run tests**

```bash
ruby -e "
require 'xcodeproj'
project = Xcodeproj::Project.open('Mos.xcodeproj')
target = project.targets.find { |t| t.name == 'MosTests' }
group = project.main_group.find_subpath('MosTests', true)
['MosTests/InterpolatorTests.swift', 'MosTests/ScrollFilterTests.swift'].each do |path|
  ref = group.new_file(path)
  target.add_file_references([ref])
end
project.save
"
xcodebuild test -scheme Debug -project Mos.xcodeproj -only-testing:MosTests/InterpolatorTests -only-testing:MosTests/ScrollFilterTests -quiet 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add MosTests/InterpolatorTests.swift MosTests/ScrollFilterTests.swift Mos.xcodeproj
git commit -m "test: add InterpolatorTests and ScrollFilterTests"
```

---

### Task 7: ScrollDispatchContextTests (P0)

**Files:**
- Create: `MosTests/ScrollDispatchContextTests.swift`

- [ ] **Step 1: Write ScrollDispatchContextTests**

```swift
import XCTest
@testable import Mos

final class ScrollDispatchContextTests: XCTestCase {

    var ctx: ScrollDispatchContext!

    override func setUp() {
        super.setUp()
        ctx = ScrollDispatchContext()
    }

    private func makeScrollEvent() -> CGEvent? {
        return CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0)
    }

    // MARK: - capture + preparePostingSnapshot

    func test_capture_stores_template() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        XCTAssertTrue(ctx.capture(event: event))
        let snapshot = ctx.preparePostingSnapshot()
        XCTAssertNotNil(snapshot)
    }

    func test_prepare_without_capture_returns_nil() {
        let snapshot = ctx.preparePostingSnapshot()
        XCTAssertNil(snapshot)
    }

    func test_snapshot_is_clone_not_original() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        ctx.capture(event: event)
        let snapshot = ctx.preparePostingSnapshot()
        // Modify original event after snapshot
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 999.0)
        // Snapshot should not be affected
        XCTAssertNotEqual(snapshot?.event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 999.0)
    }

    // MARK: - advanceGeneration

    func test_advance_generation_changes_snapshot_generation() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        ctx.capture(event: event)
        let snap1 = try XCTUnwrap(ctx.preparePostingSnapshot())
        let gen1 = snap1.generation

        ctx.advanceGeneration()
        let snap2 = try XCTUnwrap(ctx.preparePostingSnapshot())
        XCTAssertNotEqual(gen1, snap2.generation)
    }

    // MARK: - clearContext

    func test_clear_context_invalidates_snapshots() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        ctx.capture(event: event)
        ctx.clearContext()
        XCTAssertNil(ctx.preparePostingSnapshot())
    }

    // MARK: - invalidateAll

    func test_invalidate_all_clears_everything() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        ctx.capture(event: event)
        ctx.invalidateAll()
        XCTAssertNil(ctx.preparePostingSnapshot())
    }

    // MARK: - TTL

    func test_snapshot_ttl_expiry() throws {
        try XCTSkipUnless(makeScrollEvent() != nil, "CGEvent creation requires window server")
        let event = try XCTUnwrap(makeScrollEvent())
        ctx.eventTTL = 0.01 // 10ms for test
        ctx.capture(event: event)
        let snapshot = try XCTUnwrap(ctx.preparePostingSnapshot())

        // Wait for TTL to expire
        Thread.sleep(forTimeInterval: 0.05)
        ctx.enqueue(snapshot)

        // Give postQueue time to process
        let expectation = XCTestExpectation(description: "enqueue processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1.0)

        let diag = ctx.diagnosticsSnapshot()
        XCTAssertEqual(diag.droppedFramesByTTL, 1)
    }

    // MARK: - 并发安全

    func test_concurrent_capture_and_prepare_no_crash() throws {
        try XCTSkipUnless(makeScrollEvent() != nil, "CGEvent creation requires window server")
        let iterations = 500
        let group = DispatchGroup()
        let q1 = DispatchQueue(label: "test.capture", attributes: .concurrent)
        let q2 = DispatchQueue(label: "test.prepare", attributes: .concurrent)

        for _ in 0..<iterations {
            group.enter()
            q1.async {
                if let event = self.makeScrollEvent() {
                    self.ctx.capture(event: event)
                }
                group.leave()
            }
            group.enter()
            q2.async {
                _ = self.ctx.preparePostingSnapshot()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "Concurrent operations should not deadlock")
    }
}
```

- [ ] **Step 2: Add file to Xcode project and run tests**

```bash
ruby -e "
require 'xcodeproj'
project = Xcodeproj::Project.open('Mos.xcodeproj')
target = project.targets.find { |t| t.name == 'MosTests' }
group = project.main_group.find_subpath('MosTests', true)
ref = group.new_file('MosTests/ScrollDispatchContextTests.swift')
target.add_file_references([ref])
project.save
"
xcodebuild test -scheme Debug -project Mos.xcodeproj -only-testing:MosTests/ScrollDispatchContextTests -quiet 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MosTests/ScrollDispatchContextTests.swift Mos.xcodeproj
git commit -m "test: add ScrollDispatchContextTests covering generation, TTL, and concurrency"
```

---

### Task 8: ScrollEventTests (P1)

**Files:**
- Create: `MosTests/ScrollEventTests.swift`

- [ ] **Step 1: Write ScrollEventTests**

```swift
import XCTest
@testable import Mos

final class ScrollEventTests: XCTestCase {

    private func makeScrollEvent(wheel1: Int32 = 0, wheel2: Int32 = 0) -> CGEvent? {
        return CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: wheel1, wheel2: wheel2, wheel3: 0)
    }

    // MARK: - usableValue 优先级: scrollPt > scrollFixPt > scrollFix

    func test_usable_value_prefers_scrollPt() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 3.5)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 1)
        let scrollEvent = ScrollEvent(with: event)
        XCTAssertEqual(scrollEvent.Y.usableValue, 3.5)
        XCTAssertFalse(scrollEvent.Y.fixed)
        XCTAssertTrue(scrollEvent.Y.valid)
    }

    func test_usable_value_fallback_to_scrollFixPt() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0.0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 2.5)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 1)
        let scrollEvent = ScrollEvent(with: event)
        XCTAssertEqual(scrollEvent.Y.usableValue, 2.5)
        XCTAssertTrue(scrollEvent.Y.fixed)
    }

    func test_usable_value_fallback_to_scrollFix() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0.0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 3)
        let scrollEvent = ScrollEvent(with: event)
        XCTAssertEqual(scrollEvent.Y.usableValue, 3.0)
        XCTAssertTrue(scrollEvent.Y.fixed)
    }

    func test_no_data_means_invalid() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0.0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        let scrollEvent = ScrollEvent(with: event)
        XCTAssertFalse(scrollEvent.Y.valid)
        XCTAssertEqual(scrollEvent.Y.usableValue, 0.0)
    }

    // MARK: - horizontal axis

    func test_horizontal_axis_parsing() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: 7.0)
        let scrollEvent = ScrollEvent(with: event)
        XCTAssertEqual(scrollEvent.X.usableValue, 7.0)
        XCTAssertTrue(scrollEvent.X.valid)
    }

    // MARK: - reverse

    func test_reverse_y() throws {
        let event = try XCTUnwrap(makeScrollEvent(wheel1: 5))
        let scrollEvent = ScrollEvent(with: event)
        let originalY = scrollEvent.Y.usableValue
        ScrollEvent.reverseY(scrollEvent)
        XCTAssertEqual(scrollEvent.Y.usableValue, -originalY)
    }

    func test_reverse_x() throws {
        let event = try XCTUnwrap(makeScrollEvent(wheel2: 3))
        let scrollEvent = ScrollEvent(with: event)
        let originalX = scrollEvent.X.usableValue
        ScrollEvent.reverseX(scrollEvent)
        XCTAssertEqual(scrollEvent.X.usableValue, -originalX)
    }

    // MARK: - normalize

    func test_normalize_y_below_step() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0.5)
        let scrollEvent = ScrollEvent(with: event)
        ScrollEvent.normalizeY(scrollEvent, 3.0)
        XCTAssertEqual(scrollEvent.Y.usableValue, 3.0, accuracy: 1e-10)
    }

    func test_normalize_y_negative_below_step() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -0.5)
        let scrollEvent = ScrollEvent(with: event)
        ScrollEvent.normalizeY(scrollEvent, 3.0)
        XCTAssertEqual(scrollEvent.Y.usableValue, -3.0, accuracy: 1e-10)
    }

    func test_normalize_y_above_step_unchanged() throws {
        let event = try XCTUnwrap(makeScrollEvent())
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 10.0)
        let scrollEvent = ScrollEvent(with: event)
        ScrollEvent.normalizeY(scrollEvent, 3.0)
        XCTAssertEqual(scrollEvent.Y.usableValue, 10.0, accuracy: 1e-10)
    }

    // MARK: - clear

    func test_clear_y() throws {
        let event = try XCTUnwrap(makeScrollEvent(wheel1: 5))
        let scrollEvent = ScrollEvent(with: event)
        ScrollEvent.clearY(scrollEvent)
        XCTAssertEqual(scrollEvent.Y.usableValue, 0.0)
        XCTAssertEqual(scrollEvent.Y.scrollFix, 0)
        XCTAssertEqual(scrollEvent.Y.scrollPt, 0.0)
    }

    func test_clear_x() throws {
        let event = try XCTUnwrap(makeScrollEvent(wheel2: 3))
        let scrollEvent = ScrollEvent(with: event)
        ScrollEvent.clearX(scrollEvent)
        XCTAssertEqual(scrollEvent.X.usableValue, 0.0)
    }
}
```

- [ ] **Step 2: Add file to Xcode project and run tests**

```bash
ruby -e "
require 'xcodeproj'
project = Xcodeproj::Project.open('Mos.xcodeproj')
target = project.targets.find { |t| t.name == 'MosTests' }
group = project.main_group.find_subpath('MosTests', true)
ref = group.new_file('MosTests/ScrollEventTests.swift')
target.add_file_references([ref])
project.save
"
xcodebuild test -scheme Debug -project Mos.xcodeproj -only-testing:MosTests/ScrollEventTests -quiet 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MosTests/ScrollEventTests.swift Mos.xcodeproj
git commit -m "test: add ScrollEventTests covering parsing priority, reverse, normalize, clear"
```

---

### Task 9: ScrollCoreHotkeyTests (P1)

**Files:**
- Create: `MosTests/ScrollCoreHotkeyTests.swift`

- [ ] **Step 1: Write ScrollCoreHotkeyTests**

```swift
import XCTest
@testable import Mos

final class ScrollCoreHotkeyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 重置热键状态
        let sc = ScrollCore.shared
        sc.dashScroll = false
        sc.dashAmplification = 1.0
        sc.toggleScroll = false
        sc.blockSmooth = false
        sc.dashKeyHeld = false
        sc.toggleKeyHeld = false
        sc.blockKeyHeld = false
    }

    // MARK: - handleScrollHotkeyFromHIDPlusPlus

    func test_key_down_matches_dash_hotkey() {
        // 设置 dash 热键为鼠标按钮 code=5 (type=mouse)
        Options.shared.scroll.dash = ScrollHotkey(type: .mouse, code: 5)
        let matched = ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 5, isDown: true)
        XCTAssertTrue(matched)
        XCTAssertTrue(ScrollCore.shared.dashScroll)
        XCTAssertEqual(ScrollCore.shared.dashAmplification, 5.0)
    }

    func test_key_down_no_match() {
        Options.shared.scroll.dash = ScrollHotkey(type: .mouse, code: 5)
        Options.shared.scroll.toggle = nil
        Options.shared.scroll.block = nil
        let matched = ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 99, isDown: true)
        XCTAssertFalse(matched)
        XCTAssertFalse(ScrollCore.shared.dashScroll)
    }

    func test_key_up_clears_by_tracked_code() {
        Options.shared.scroll.dash = ScrollHotkey(type: .mouse, code: 5)
        // key-down
        ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 5, isDown: true)
        XCTAssertTrue(ScrollCore.shared.dashScroll)
        // key-up with same code
        let matched = ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 5, isDown: false)
        XCTAssertTrue(matched)
        XCTAssertFalse(ScrollCore.shared.dashScroll)
        XCTAssertEqual(ScrollCore.shared.dashAmplification, 1.0)
    }

    func test_key_up_wrong_code_does_not_clear() {
        Options.shared.scroll.dash = ScrollHotkey(type: .mouse, code: 5)
        ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 5, isDown: true)
        let matched = ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 99, isDown: false)
        XCTAssertFalse(matched)
        XCTAssertTrue(ScrollCore.shared.dashScroll) // 未被清除
    }

    func test_keyboard_type_hotkey_not_matched_by_hidpp() {
        // HID++ 只匹配 type == .mouse
        Options.shared.scroll.dash = ScrollHotkey(type: .keyboard, code: 5)
        let matched = ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 5, isDown: true)
        XCTAssertFalse(matched)
    }

    func test_multiple_hotkeys_simultaneously() {
        Options.shared.scroll.dash = ScrollHotkey(type: .mouse, code: 5)
        Options.shared.scroll.toggle = ScrollHotkey(type: .mouse, code: 6)
        ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 5, isDown: true)
        ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 6, isDown: true)
        XCTAssertTrue(ScrollCore.shared.dashScroll)
        XCTAssertTrue(ScrollCore.shared.toggleScroll)
        // Release only dash
        ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus(code: 5, isDown: false)
        XCTAssertFalse(ScrollCore.shared.dashScroll)
        XCTAssertTrue(ScrollCore.shared.toggleScroll) // toggle 未受影响
    }
}
```

- [ ] **Step 2: Add file to Xcode project and run tests**

```bash
ruby -e "
require 'xcodeproj'
project = Xcodeproj::Project.open('Mos.xcodeproj')
target = project.targets.find { |t| t.name == 'MosTests' }
group = project.main_group.find_subpath('MosTests', true)
ref = group.new_file('MosTests/ScrollCoreHotkeyTests.swift')
target.add_file_references([ref])
project.save
"
xcodebuild test -scheme Debug -project Mos.xcodeproj -only-testing:MosTests/ScrollCoreHotkeyTests -quiet 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add MosTests/ScrollCoreHotkeyTests.swift Mos.xcodeproj
git commit -m "test: add ScrollCoreHotkeyTests for HID++ hotkey matching"
```

---

### Task 10: ScrollPosterStateTests + ScrollHotkeyTests (P2)

**Files:**
- Create: `MosTests/ScrollPosterStateTests.swift`
- Create: `MosTests/ScrollHotkeyTests.swift`

- [ ] **Step 1: Write ScrollPosterStateTests**

```swift
import XCTest
@testable import Mos

final class ScrollPosterStateTests: XCTestCase {

    // MARK: - shift()

    func test_shift_no_shifting() {
        ScrollPoster.shared.updateShifting(enable: false)
        let result = ScrollPoster.shared.shift(with: (y: 5.0, x: 0.0))
        XCTAssertEqual(result.y, 5.0)
        XCTAssertEqual(result.x, 0.0)
    }

    func test_shift_vertical_to_horizontal() {
        ScrollPoster.shared.updateShifting(enable: true)
        let result = ScrollPoster.shared.shift(with: (y: 5.0, x: 0.0))
        // Y有值X无值 -> 交换: Y=0, X=5
        XCTAssertEqual(result.y, 0.0)
        XCTAssertEqual(result.x, 5.0)
    }

    func test_shift_already_horizontal() {
        ScrollPoster.shared.updateShifting(enable: true)
        let result = ScrollPoster.shared.shift(with: (y: 0.0, x: 5.0))
        // Y无值X有值 -> 不满足交换条件, 保持
        XCTAssertEqual(result.y, 0.0)
        XCTAssertEqual(result.x, 5.0)
    }

    func test_shift_both_axes_no_swap() {
        ScrollPoster.shared.updateShifting(enable: true)
        let result = ScrollPoster.shared.shift(with: (y: 3.0, x: 2.0))
        // 双轴都有值 -> 不交换 (MXMaster 归一化)
        XCTAssertEqual(result.y, 3.0)
        XCTAssertEqual(result.x, 2.0)
    }

    override func tearDown() {
        ScrollPoster.shared.updateShifting(enable: false)
        super.tearDown()
    }
}
```

- [ ] **Step 2: Write ScrollHotkeyTests**

```swift
import XCTest
@testable import Mos

final class ScrollHotkeyTests: XCTestCase {

    func test_modifier_key_detection_command() {
        let hotkey = ScrollHotkey(type: .keyboard, code: 55) // Left Command
        XCTAssertTrue(hotkey.isModifierKey)
    }

    func test_modifier_key_detection_shift() {
        let hotkey = ScrollHotkey(type: .keyboard, code: 56) // Left Shift
        XCTAssertTrue(hotkey.isModifierKey)
    }

    func test_modifier_key_detection_option() {
        let hotkey = ScrollHotkey(type: .keyboard, code: 58) // Left Option
        XCTAssertTrue(hotkey.isModifierKey)
    }

    func test_non_modifier_key() {
        let hotkey = ScrollHotkey(type: .keyboard, code: 0) // 'A' key
        XCTAssertFalse(hotkey.isModifierKey)
    }

    func test_mouse_type_is_not_modifier() {
        let hotkey = ScrollHotkey(type: .mouse, code: 3)
        XCTAssertFalse(hotkey.isModifierKey)
    }

    func test_matches_keyboard_event() throws {
        let hotkey = ScrollHotkey(type: .keyboard, code: 0) // 'A' key
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let matched = hotkey.matches(event, keyCode: 0, mouseButton: 0, isMouseEvent: false)
        XCTAssertTrue(matched)
    }

    func test_matches_mouse_event() {
        let hotkey = ScrollHotkey(type: .mouse, code: 3)
        // 无需构造真实 CGEvent, matches 对鼠标事件只检查 isMouseEvent + mouseButton
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!
        let matched = hotkey.matches(event, keyCode: 0, mouseButton: 3, isMouseEvent: true)
        XCTAssertTrue(matched)
    }

    func test_mouse_hotkey_does_not_match_keyboard() {
        let hotkey = ScrollHotkey(type: .mouse, code: 3)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!
        let matched = hotkey.matches(event, keyCode: 3, mouseButton: 0, isMouseEvent: false)
        XCTAssertFalse(matched)
    }
}
```

- [ ] **Step 3: Add files to Xcode project and run tests**

```bash
ruby -e "
require 'xcodeproj'
project = Xcodeproj::Project.open('Mos.xcodeproj')
target = project.targets.find { |t| t.name == 'MosTests' }
group = project.main_group.find_subpath('MosTests', true)
['MosTests/ScrollPosterStateTests.swift', 'MosTests/ScrollHotkeyTests.swift'].each do |path|
  ref = group.new_file(path)
  target.add_file_references([ref])
end
project.save
"
xcodebuild test -scheme Debug -project Mos.xcodeproj -only-testing:MosTests/ScrollPosterStateTests -only-testing:MosTests/ScrollHotkeyTests -quiet 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add MosTests/ScrollPosterStateTests.swift MosTests/ScrollHotkeyTests.swift Mos.xcodeproj
git commit -m "test: add ScrollPosterStateTests and ScrollHotkeyTests"
```
