# Custom Shortcut Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to record custom key/modifier combinations as button binding actions with 1:1 down/up passthrough execution.

**Architecture:** Adds `.adaptive` recording mode to `KeyRecorder` with timing-based intent detection, extends `ButtonBinding` to store custom bindings via `custom::<code>:<modifiers>` encoding in the existing `systemShortcutName` field, and modifies `MosInputProcessor` to track active bindings for reliable down/up pairing.

**Tech Stack:** Swift 4+, AppKit (NSMenu, NSPopUpButton, KeyPopover), CGEvent, macOS 10.13+

**Spec:** `docs/superpowers/specs/2026-04-01-custom-shortcut-binding-design.md`

---

### Task 1: Data Model — ButtonBinding Cache Fields & Init

**Files:**
- Modify: `Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift:189-230`

- [ ] **Step 1: Write failing tests for ButtonBinding cache and init**

Create test file:

```swift
// MosTests/ButtonBindingTests.swift
import XCTest
@testable import Mos_Debug

final class ButtonBindingTests: XCTestCase {

    // MARK: - prepareCustomCache

    func testPrepareCustomCache_regularKey() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::40:1048576"
        )
        binding.prepareCustomCache()
        XCTAssertEqual(binding.cachedCustomCode, 40)
        XCTAssertEqual(binding.cachedCustomModifiers, 1048576) // ⌘
    }

    func testPrepareCustomCache_modifierKey_stripsRedundantFlag() {
        // Shift keyCode=56, maskShift=131072. When recording Shift alone,
        // modifiers may include maskShift — prepareCustomCache must strip it.
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::56:131072"
        )
        binding.prepareCustomCache()
        XCTAssertEqual(binding.cachedCustomCode, 56)
        XCTAssertEqual(binding.cachedCustomModifiers, 0) // self-flag stripped
    }

    func testPrepareCustomCache_nonCustomBinding() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "missionControl"
        )
        binding.prepareCustomCache()
        XCTAssertNil(binding.cachedCustomCode)
        XCTAssertNil(binding.cachedCustomModifiers)
    }

    func testPrepareCustomCache_invalidFormat() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::abc:xyz"
        )
        binding.prepareCustomCache()
        XCTAssertNil(binding.cachedCustomCode)
        XCTAssertNil(binding.cachedCustomModifiers)
    }

    // MARK: - Init with createdAt

    func testInit_withCreatedAt_preservesTimestamp() {
        let pastDate = Date(timeIntervalSince1970: 1000000)
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "test",
            createdAt: pastDate
        )
        XCTAssertEqual(binding.createdAt, pastDate)
    }

    func testInit_defaultCreatedAt_usesNow() {
        let before = Date()
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "test"
        )
        let after = Date()
        XCTAssertGreaterThanOrEqual(binding.createdAt, before)
        XCTAssertLessThanOrEqual(binding.createdAt, after)
    }

    // MARK: - Codable roundtrip

    func testCodableRoundtrip_preservesFields() {
        let original = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::56:0"
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(ButtonBinding.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.systemShortcutName, "custom::56:0")
        XCTAssertNil(decoded.cachedCustomCode) // transient, not encoded
    }

    // MARK: - Equatable

    func testEquatable_ignoresTransientCache() {
        var a = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::56:0"
        )
        var b = a
        a.prepareCustomCache()
        // b has no cache, a has cache — should still be equal
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Debug -only-testing:MosTests/ButtonBindingTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: Compilation errors — `cachedCustomCode`, `prepareCustomCache()`, `createdAt` parameter don't exist yet.

- [ ] **Step 3: Implement ButtonBinding changes**

In `Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift`, replace lines 189-230 (the entire `ButtonBinding` struct) with:

```swift
// MARK: - ButtonBinding
/// 按钮绑定 - 将录制的事件与系统快捷键关联
struct ButtonBinding: Codable, Equatable {

    // MARK: - 数据字段

    /// 唯一标识符
    let id: UUID

    /// 录制的触发事件
    let triggerEvent: RecordedEvent

    /// 绑定的系统快捷键名称
    /// 预定义快捷键: SystemShortcut identifier (如 "missionControl")
    /// 自定义绑定: "custom::<keyCode>:<modifierFlags>" (如 "custom::56:0")
    let systemShortcutName: String

    /// 是否启用
    var isEnabled: Bool

    /// 创建时间
    let createdAt: Date

    // MARK: - Transient Cache (NOT part of Codable or Equatable)
    // 注意: 添加新持久化字段时必须同步更新 CodingKeys
    private(set) var cachedCustomCode: UInt16? = nil
    private(set) var cachedCustomModifiers: UInt64? = nil

    // MARK: - CodingKeys
    enum CodingKeys: String, CodingKey {
        case id, triggerEvent, systemShortcutName, isEnabled, createdAt
    }

    // MARK: - 计算属性

    /// 获取系统快捷键对象
    var systemShortcut: SystemShortcut.Shortcut? {
        return SystemShortcut.getShortcut(named: systemShortcutName)
    }

    /// 是否为自定义绑定
    var isCustomBinding: Bool {
        return systemShortcutName.hasPrefix("custom::")
    }

    // MARK: - 初始化

    init(id: UUID = UUID(), triggerEvent: RecordedEvent, systemShortcutName: String, isEnabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.triggerEvent = triggerEvent
        self.systemShortcutName = systemShortcutName
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    // MARK: - Custom Cache

    /// 预解析 custom:: 绑定的 keyCode 和 modifiers (加载时调用一次, 避免热路径字符串解析)
    mutating func prepareCustomCache() {
        guard systemShortcutName.hasPrefix("custom::") else { return }
        let parts = systemShortcutName.dropFirst(8).split(separator: ":")
        guard parts.count == 2,
              let code = UInt16(parts[0]),
              let mods = UInt64(parts[1]) else { return }
        cachedCustomCode = code
        // 清理冗余修饰键 flag: 录制修饰键时 modifiers 可能包含自身 flag
        var cleanedMods = mods
        if KeyCode.modifierKeys.contains(code) {
            let selfFlag = KeyCode.getKeyMask(code).rawValue
            cleanedMods = mods & ~selfFlag
        }
        cachedCustomModifiers = cleanedMods
    }

    // MARK: - Equatable (基于持久化字段)

    static func == (lhs: ButtonBinding, rhs: ButtonBinding) -> Bool {
        return lhs.id == rhs.id
            && lhs.triggerEvent == rhs.triggerEvent
            && lhs.systemShortcutName == rhs.systemShortcutName
            && lhs.isEnabled == rhs.isEnabled
            && lhs.createdAt == rhs.createdAt
    }
}
```

Also add `RecordedEvent` convenience initializer for tests (after the existing inits, around line 141):

```swift
    /// 直接构造 (用于测试和自定义绑定)
    init(type: EventType, code: UInt16, modifiers: UInt, displayComponents: [String], deviceFilter: DeviceFilter?) {
        self.type = type
        self.code = code
        self.modifiers = modifiers
        self.displayComponents = displayComponents
        self.deviceFilter = deviceFilter
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Debug -only-testing:MosTests/ButtonBindingTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: All 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add MosTests/ButtonBindingTests.swift Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift
git commit -m "feat(data-model): add ButtonBinding cache fields, createdAt param, custom:: support"
```

---

### Task 2: ButtonUtils Cache Layer

**Files:**
- Modify: `Mos/ButtonCore/ButtonUtils.swift:11-42`

- [ ] **Step 1: Write failing tests for ButtonUtils cache**

```swift
// MosTests/ButtonUtilsCacheTests.swift
import XCTest
@testable import Mos_Debug

final class ButtonUtilsCacheTests: XCTestCase {

    func testInvalidateCache_causesFreshLoad() {
        // After invalidation, getButtonBindings should re-read from Options
        ButtonUtils.shared.invalidateCache()
        let bindings = ButtonUtils.shared.getButtonBindings()
        // Should succeed without crash (validates cache mechanism works)
        XCTAssertNotNil(bindings)
    }

    func testGetButtonBindings_preparesCustomCache() {
        // Setup: add a custom binding to Options
        let trigger = RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil)
        let binding = ButtonBinding(triggerEvent: trigger, systemShortcutName: "custom::56:0", isEnabled: true)
        Options.shared.buttons.binding = [binding]
        ButtonUtils.shared.invalidateCache()

        let loaded = ButtonUtils.shared.getButtonBindings()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].cachedCustomCode, 56)
        XCTAssertEqual(loaded[0].cachedCustomModifiers, 0)

        // Cleanup
        Options.shared.buttons.binding = []
        ButtonUtils.shared.invalidateCache()
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Debug -only-testing:MosTests/ButtonUtilsCacheTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: FAIL — `invalidateCache()` method does not exist.

- [ ] **Step 3: Implement ButtonUtils cache**

Replace the entire content of `Mos/ButtonCore/ButtonUtils.swift`:

```swift
//
//  ButtonUtils.swift
//  Mos
//  按钮绑定工具类 - 获取配置和管理绑定 (带缓存)
//  Created by Claude on 2025/8/10.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

class ButtonUtils {

    // 单例
    static let shared = ButtonUtils()
    init() {}

    // MARK: - 缓存

    /// 缓存的绑定列表 (已预解析 custom:: 字段)
    private var cachedBindings: [ButtonBinding] = []
    private var isDirty = true

    // MARK: - 获取按钮绑定配置

    /// 获取当前应用的按钮绑定配置 (带缓存和预解析)
    /// - Returns: 按钮绑定列表
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

    /// 标记缓存失效 (绑定变更后调用)
    func invalidateCache() {
        isDirty = true
    }

    // MARK: - 分应用支持 (预留接口)

    /// 获取当前焦点应用的配置对象 (预留)
    /// - Returns: Application 对象或 nil
    private func getTargetApplication() -> Application? {
        return nil
    }
}
```

- [ ] **Step 4: Add invalidateCache() calls to sync points**

In `Mos/Windows/PreferencesWindow/ButtonsView/PreferencesButtonsViewController.swift`, add at line 77 (inside `syncViewWithOptions()`), after `Options.shared.buttons.binding = buttonBindings`:

```swift
        ButtonUtils.shared.invalidateCache()
```

In `Mos/Options/Options.swift`, in `readOptions()` method, after `buttons.binding = loadButtonsData()` add:

```swift
        ButtonUtils.shared.invalidateCache()
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme Debug -only-testing:MosTests/ButtonUtilsCacheTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: All 2 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Mos/ButtonCore/ButtonUtils.swift Mos/Windows/PreferencesWindow/ButtonsView/PreferencesButtonsViewController.swift Mos/Options/Options.swift MosTests/ButtonUtilsCacheTests.swift
git commit -m "feat(cache): add ButtonUtils cached bindings with prepareCustomCache"
```

---

### Task 3: Execution Model — MosInputProcessor Active Bindings + ShortcutExecutor Custom

**Files:**
- Modify: `Mos/InputEvent/MosInputProcessor.swift:18-43`
- Modify: `Mos/Shortcut/ShortcutExecutor.swift:55-82`
- Modify: `Mos/ButtonCore/ButtonCore.swift:29-31`
- Modify: `Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift:166-168`

- [ ] **Step 1: Write failing tests**

```swift
// MosTests/MosInputProcessorTests.swift
import XCTest
@testable import Mos_Debug

final class MosInputProcessorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Options.shared.buttons.binding = []
        ButtonUtils.shared.invalidateCache()
    }

    override func tearDown() {
        Options.shared.buttons.binding = []
        ButtonUtils.shared.invalidateCache()
        super.tearDown()
    }

    // MARK: - Active Bindings Table

    func testProcess_downEvent_consumedWhenBindingMatches() {
        let trigger = RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil)
        let binding = ButtonBinding(triggerEvent: trigger, systemShortcutName: "custom::56:0", isEnabled: true)
        Options.shared.buttons.binding = [binding]
        ButtonUtils.shared.invalidateCache()

        let event = MosInputEvent(type: .mouse, code: 3, modifiers: CGEventFlags(rawValue: 0),
                                   phase: .down, source: .hidPlusPlus, device: nil)
        let result = MosInputProcessor.shared.process(event)
        XCTAssertEqual(result, .consumed)
    }

    func testProcess_upEvent_consumedViaActiveBindings() {
        let trigger = RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil)
        let binding = ButtonBinding(triggerEvent: trigger, systemShortcutName: "custom::56:0", isEnabled: true)
        Options.shared.buttons.binding = [binding]
        ButtonUtils.shared.invalidateCache()

        // Down first
        let downEvent = MosInputEvent(type: .mouse, code: 3, modifiers: CGEventFlags(rawValue: 0),
                                       phase: .down, source: .hidPlusPlus, device: nil)
        _ = MosInputProcessor.shared.process(downEvent)

        // Up — should match via active bindings table
        let upEvent = MosInputEvent(type: .mouse, code: 3, modifiers: CGEventFlags(rawValue: 0),
                                     phase: .up, source: .hidPlusPlus, device: nil)
        let result = MosInputProcessor.shared.process(upEvent)
        XCTAssertEqual(result, .consumed)
    }

    func testProcess_upEvent_passthroughWithoutPriorDown() {
        let event = MosInputEvent(type: .mouse, code: 99, modifiers: CGEventFlags(rawValue: 0),
                                   phase: .up, source: .hidPlusPlus, device: nil)
        let result = MosInputProcessor.shared.process(event)
        XCTAssertEqual(result, .passthrough)
    }

    func testProcess_upEvent_matchesDespiteModifierChange() {
        // Trigger recorded with ⌘ modifier
        let trigger = RecordedEvent(type: .mouse, code: 3, modifiers: UInt(CGEventFlags.maskCommand.rawValue),
                                     displayComponents: ["⌘", "🖱4"], deviceFilter: nil)
        let binding = ButtonBinding(triggerEvent: trigger, systemShortcutName: "custom::56:0", isEnabled: true)
        Options.shared.buttons.binding = [binding]
        ButtonUtils.shared.invalidateCache()

        // Down with ⌘ held
        let downEvent = MosInputEvent(type: .mouse, code: 3, modifiers: .maskCommand,
                                       phase: .down, source: .hidPlusPlus, device: nil)
        _ = MosInputProcessor.shared.process(downEvent)

        // Up with ⌘ already released (modifiers = 0)
        let upEvent = MosInputEvent(type: .mouse, code: 3, modifiers: CGEventFlags(rawValue: 0),
                                     phase: .up, source: .hidPlusPlus, device: nil)
        let result = MosInputProcessor.shared.process(upEvent)
        XCTAssertEqual(result, .consumed) // active bindings table matches by (type, code) only
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Debug -only-testing:MosTests/MosInputProcessorTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: FAIL — `MosInputResult` doesn't conform to `Equatable`, active bindings table doesn't exist.

- [ ] **Step 3: Add Equatable to MosInputResult**

In `Mos/InputEvent/MosInputProcessor.swift` line 13, change:

```swift
enum MosInputResult {
```

to:

```swift
enum MosInputResult: Equatable {
```

- [ ] **Step 4: Remove .down guard from RecordedEvent.matchesMosInput()**

In `Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift` line 167-168, remove:

```swift
            guard event.phase == .down else { return false }
```

So the keyboard case becomes just:

```swift
        case .keyboard:
            guard code == event.code else { return false }
```

- [ ] **Step 5: Add Up event masks to ButtonCore**

In `Mos/ButtonCore/ButtonCore.swift`, add after line 28:

```swift
    let otherUp = CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
    let keyUp = CGEventMask(1 << CGEventType.keyUp.rawValue)
```

And change line 30 (`eventMask`) to:

```swift
    var eventMask: CGEventMask {
        return leftDown | rightDown | otherDown | otherUp | keyDown | keyUp
    }
```

- [ ] **Step 6: Implement MosInputProcessor active bindings table**

Replace the entire content of `Mos/InputEvent/MosInputProcessor.swift`:

```swift
//
//  MosInputProcessor.swift
//  Mos
//  统一事件处理器 - 接收 MosInputEvent, 匹配 ButtonBinding, 执行动作
//  Created by Mos on 2026/3/16.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

// MARK: - MosInputResult
/// 事件处理结果
enum MosInputResult: Equatable {
    case consumed     // 事件已处理,不再传递
    case passthrough  // 事件未匹配,继续传递
}

// MARK: - MosInputProcessor
/// 统一事件处理器
/// 从 ButtonUtils 获取绑定配置, 匹配 MosInputEvent, 执行 ShortcutExecutor
/// 使用 activeBindings 表跟踪按下中的绑定, 确保 Up 事件正确配对
class MosInputProcessor {
    static let shared = MosInputProcessor()
    init() { NSLog("Module initialized: MosInputProcessor") }

    // MARK: - Active Bindings Table
    /// 跟踪当前按下的绑定, 用于 Up 事件配对
    /// Key: (EventType, keyCode)  Value: 匹配到的 ButtonBinding
    private var activeBindings: [TriggerKey: ButtonBinding] = [:]

    private struct TriggerKey: Hashable {
        let type: EventType
        let code: UInt16
    }

    /// 处理输入事件
    /// - Parameter event: 统一输入事件
    /// - Returns: .consumed 表示事件已处理, .passthrough 表示未匹配
    func process(_ event: MosInputEvent) -> MosInputResult {
        let key = TriggerKey(type: event.type, code: event.code)

        if event.phase == .up {
            // Up 事件: 按 (type, code) 查表, 忽略 modifiers (用户可能已松开修饰键)
            if let binding = activeBindings.removeValue(forKey: key) {
                ShortcutExecutor.shared.execute(named: binding.systemShortcutName, phase: .up, binding: binding)
                return .consumed
            }
            return .passthrough
        }

        // Down 事件: 完整匹配 (type + code + modifiers + deviceFilter)
        let bindings = ButtonUtils.shared.getButtonBindings()
        for binding in bindings where binding.isEnabled {
            if binding.triggerEvent.matchesMosInput(event) {
                activeBindings[key] = binding
                ShortcutExecutor.shared.execute(named: binding.systemShortcutName, phase: .down, binding: binding)
                return .consumed
            }
        }
        return .passthrough
    }
}
```

- [ ] **Step 7: Implement ShortcutExecutor custom binding support**

In `Mos/Shortcut/ShortcutExecutor.swift`, replace lines 55-82 (the `execute(named:)` method) with:

```swift
    /// 执行系统快捷键 (从名称解析, 支持动态读取系统配置)
    /// - Parameters:
    ///   - shortcutName: 快捷键名称
    ///   - phase: 事件阶段 (down/up), 默认 .down
    ///   - binding: 可选的 ButtonBinding (用于访问预解析的 custom cache)
    func execute(named shortcutName: String, phase: MosInputPhase = .down, binding: ButtonBinding? = nil) {
        // 自定义绑定: 根据 phase 发送 keyDown/keyUp 或 flagsChanged
        if let code = binding?.cachedCustomCode {
            let modifiers = binding?.cachedCustomModifiers ?? 0
            executeCustom(code: code, modifiers: modifiers, phase: phase)
            return
        }

        // 以下预定义类型仅响应 down
        guard phase == .down else { return }

        // 鼠标按键动作
        if shortcutName.hasPrefix("mouse") {
            executeMouseAction(shortcutName)
            return
        }

        // Logi HID++ 动作
        if shortcutName.hasPrefix("logi") {
            executeLogiAction(shortcutName)
            return
        }

        // 优先使用系统实际配置 (对于Mission Control相关快捷键)
        if let resolved = SystemShortcut.resolveSystemShortcut(shortcutName) {
            execute(code: resolved.code, flags: resolved.modifiers)
            return
        }

        // Fallback到内置快捷键定义
        guard let shortcut = SystemShortcut.getShortcut(named: shortcutName) else {
            return
        }

        execute(shortcut)
    }

    // MARK: - Custom Binding Execution

    /// 执行自定义绑定 (1:1 down/up 映射)
    private func executeCustom(code: UInt16, modifiers: UInt64, phase: MosInputPhase) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let isModifierKey = KeyCode.modifierKeys.contains(code)

        if isModifierKey {
            // 修饰键: 使用 flagsChanged 事件类型
            guard let event = CGEvent(source: source) else { return }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            if phase == .down {
                // 按下: 设置所有修饰键 flags (自身 + 附加修饰键)
                let keyMask = KeyCode.getKeyMask(code)
                event.flags = CGEventFlags(rawValue: modifiers | keyMask.rawValue)
            } else {
                // 松开: 清除所有 flags (释放全部修饰键)
                // 注意: 对于多修饰键绑定 (如 Cmd+Shift), modifiers 含非自身 flag,
                // 必须发送 flags=0 才能完全释放, 否则系统认为部分修饰键仍按下
                event.flags = CGEventFlags(rawValue: 0)
            }
            event.post(tap: .cghidEventTap)
        } else {
            // 普通键: 使用 keyDown/keyUp
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: phase == .down) else { return }
            event.flags = CGEventFlags(rawValue: modifiers)
            event.post(tap: .cghidEventTap)
        }
    }
```

- [ ] **Step 8: Run tests**

Run: `xcodebuild test -scheme Debug -only-testing:MosTests/MosInputProcessorTests -destination 'platform=macOS' 2>&1 | tail -20`

Expected: All 4 tests PASS.

- [ ] **Step 9: Commit**

```bash
git add Mos/InputEvent/MosInputProcessor.swift Mos/Shortcut/ShortcutExecutor.swift Mos/ButtonCore/ButtonCore.swift Mos/Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift MosTests/MosInputProcessorTests.swift
git commit -m "feat(execution): active bindings table for down/up pairing, custom key execution"
```

---

### Task 4: LogitechDeviceSession — Update Independent Binding Path

**Files:**
- Modify: `Mos/LogitechHID/LogitechDeviceSession.swift:1564-1578`

- [ ] **Step 1: Update LogitechDeviceSession binding path**

Replace lines 1564-1578 in `LogitechDeviceSession.swift`:

```swift
        // 匹配 binding: logi* 动作在当前 session 执行 (设备隔离, 仅 down)
        // 其余一律走 MosInputProcessor (支持 down/up 和 custom 绑定)
        if isDown {
            let bindings = ButtonUtils.shared.getButtonBindings()
            if let binding = bindings.first(where: { $0.triggerEvent.matchesMosInput(mosEvent) && $0.isEnabled }),
               binding.systemShortcutName.hasPrefix("logi") {
                // Logi 动作: 在当前 session 执行 (设备隔离, 不注册 activeBindings)
                executeLogiAction(binding.systemShortcutName)
                return
            }
        }
        // 非 logi 绑定 (含 custom::) 和所有 Up 事件: 统一走 MosInputProcessor
        let result = MosInputProcessor.shared.process(mosEvent)
        if result == .consumed { return }
```

- [ ] **Step 2: Build to verify no compilation errors**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | grep -E '(error:|BUILD)' | tail -10`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Mos/LogitechHID/LogitechDeviceSession.swift
git commit -m "feat(logi): route Logi button up events through MosInputProcessor for custom bindings"
```

---

### Task 5: Adaptive Recording Mode in KeyRecorder

**Files:**
- Modify: `Mos/Keys/KeyRecorder.swift`

- [ ] **Step 1: Add `.adaptive` to KeyRecordingMode**

In `Mos/Keys/KeyRecorder.swift` line 13-18, add the new case:

```swift
enum KeyRecordingMode {
    /// 组合键模式：需要修饰键+普通键的组合 (用于 ButtonsView)
    case combination
    /// 单键模式：支持单个按键，包括单独的修饰键 (用于 ScrollingView)
    case singleKey
    /// 自适应模式：支持所有输入类型，通过时间间隔判断意图 (用于自定义绑定)
    case adaptive
}
```

- [ ] **Step 2: Add adaptive state machine and timers**

After `private var hidEventObserver: NSObjectProtocol?` (line 53), add:

```swift
    // Adaptive mode state
    private enum AdaptiveState {
        case idle
        case modifierHeld(modifiers: CGEventFlags)
        case modifierReleasedWaiting(modifiers: CGEventFlags)
        case recorded
    }
    private var adaptiveState: AdaptiveState = .idle
    private var adaptiveConfirmTimer: Timer?  // 300ms post-release timer
    private var holdConfirmTimer: Timer?       // 9.5s fallback timer

    // Adaptive mode constants
    private static let ADAPTIVE_CONFIRM_DELAY: TimeInterval = 0.3
    private static let HOLD_CONFIRM_DELAY: TimeInterval = 9.5
```

- [ ] **Step 3: Add `isRecordableAsAdaptive` to MosInputEvent**

In `Mos/InputEvent/MosInputEvent.swift`, add after `isRecordableAsSingleKey` (line 154):

```swift
    /// 事件是否可录制 (adaptive 模式 — 接受所有可用输入)
    var isRecordableAsAdaptive: Bool {
        switch type {
        case .keyboard:
            // 修饰键: 只在 down 时录制
            if KeyCode.modifierKeys.contains(code) {
                return phase == .down
            }
            return true
        case .mouse:
            // 主鼠标键不允许录制 (左键、右键)
            if KeyCode.mouseMainKeys.contains(code) { return false }
            return true
        }
    }
```

- [ ] **Step 4: Add adaptive event handling in handleModifierFlagsChanged**

In `Mos/Keys/KeyRecorder.swift`, in `handleModifierFlagsChanged` (line 192), add the adaptive mode branch. Replace lines 192-216:

```swift
    @objc private func handleModifierFlagsChanged(_ notification: NSNotification) {
        guard isRecording && !isRecorded else { return }
        let event = notification.object as! CGEvent

        // Adaptive 模式: 使用状态机处理修饰键
        if recordingMode == .adaptive {
            handleAdaptiveFlagsChanged(event)
            return
        }

        // 单键模式：修饰键按下时直接完成录制
        if recordingMode == .singleKey && event.isKeyDown && event.isModifiers {
            NSLog("[EventRecorder] Single key mode: modifier key recorded")
            NotificationCenter.default.post(
                name: KeyRecorder.FINISH_NOTI_NAME,
                object: event
            )
            return
        }

        // 组合键模式：如果有修饰键被按下，刷新超时定时器给用户更多时间
        let hasActiveModifiers = event.hasModifiers
        if hasActiveModifiers {
            startTimeoutTimer()
            NSLog("[EventRecorder] Modifier key pressed, timeout timer refreshed")
        }
        // 实时更新录制界面显示当前已按下的修饰键
        keyPopover?.keyPreview
            .updateForRecording(from: event)
    }
```

- [ ] **Step 5: Implement adaptive flags changed handler**

Add below `handleModifierFlagsChanged`:

```swift
    // MARK: - Adaptive Mode

    private func handleAdaptiveFlagsChanged(_ event: CGEvent) {
        let hasActiveModifiers = event.hasModifiers

        if hasActiveModifiers {
            // 修饰键按下
            cancelAdaptiveConfirmTimer()
            startHoldConfirmTimer()
            startTimeoutTimer() // 刷新全局超时
            adaptiveState = .modifierHeld(modifiers: event.flags)
            NSLog("[EventRecorder] Adaptive: modifier held, flags=\(event.flags.rawValue)")
            // 实时更新显示
            keyPopover?.keyPreview.updateForRecording(from: event)
        } else {
            // 所有修饰键松开
            switch adaptiveState {
            case .modifierHeld(let modifiers):
                // 从按住状态松开 → 启动 300ms 确认定时器
                adaptiveState = .modifierReleasedWaiting(modifiers: modifiers)
                startAdaptiveConfirmTimer(modifiers: modifiers)
                NSLog("[EventRecorder] Adaptive: modifiers released, waiting 300ms for confirmation")
            default:
                break
            }
        }
    }

    /// Adaptive 模式下的事件完成处理
    /// 在 handleRecordedEvent 前检查: 非修饰键立即录制, 组合键立即录制
    private func handleAdaptiveRecordedEvent(_ event: MosInputEvent) {
        // 取消所有 adaptive 定时器
        cancelAdaptiveConfirmTimer()
        cancelHoldConfirmTimer()
        // 状态重置
        adaptiveState = .recorded
    }

    /// 确认录制当前修饰键组合 (300ms 定时器或 9.5s hold 定时器触发)
    private func confirmAdaptiveModifiers(_ modifiers: CGEventFlags) {
        guard isRecording && !isRecorded else { return }
        cancelAdaptiveConfirmTimer()
        cancelHoldConfirmTimer()
        adaptiveState = .recorded

        // 构造 MosInputEvent 并通过 FINISH 通知完成录制
        let mosEvent = MosInputEvent(
            type: .keyboard,
            code: extractPrimaryModifierCode(from: modifiers),
            modifiers: modifiers,
            phase: .down,
            source: .hidPlusPlus, // 标记为非 CGEvent 源
            device: nil
        )
        NotificationCenter.default.post(
            name: KeyRecorder.FINISH_NOTI_NAME,
            object: mosEvent
        )
    }

    /// 从 flags 中提取主要修饰键的 keyCode
    private func extractPrimaryModifierCode(from flags: CGEventFlags) -> UInt16 {
        // 优先级: Command > Shift > Option > Control > Fn
        if flags.rawValue & CGEventFlags.maskCommand.rawValue != 0 { return KeyCode.commandL }
        if flags.rawValue & CGEventFlags.maskShift.rawValue != 0 { return KeyCode.shiftL }
        if flags.rawValue & CGEventFlags.maskAlternate.rawValue != 0 { return KeyCode.optionL }
        if flags.rawValue & CGEventFlags.maskControl.rawValue != 0 { return KeyCode.controlL }
        if flags.rawValue & CGEventFlags.maskSecondaryFn.rawValue != 0 { return KeyCode.fnL }
        return KeyCode.commandL // fallback
    }

    // MARK: - Adaptive Timers

    private func startAdaptiveConfirmTimer(modifiers: CGEventFlags) {
        cancelAdaptiveConfirmTimer()
        adaptiveConfirmTimer = Timer.scheduledTimer(withTimeInterval: KeyRecorder.ADAPTIVE_CONFIRM_DELAY, repeats: false) { [weak self] _ in
            NSLog("[EventRecorder] Adaptive: 300ms confirm timer fired, confirming modifier(s)")
            self?.confirmAdaptiveModifiers(modifiers)
        }
    }

    private func cancelAdaptiveConfirmTimer() {
        adaptiveConfirmTimer?.invalidate()
        adaptiveConfirmTimer = nil
    }

    private func startHoldConfirmTimer() {
        cancelHoldConfirmTimer()
        holdConfirmTimer = Timer.scheduledTimer(withTimeInterval: KeyRecorder.HOLD_CONFIRM_DELAY, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            NSLog("[EventRecorder] Adaptive: 9.5s hold timer fired")
            if case .modifierHeld(let modifiers) = self.adaptiveState {
                self.confirmAdaptiveModifiers(modifiers)
            }
        }
    }

    private func cancelHoldConfirmTimer() {
        holdConfirmTimer?.invalidate()
        holdConfirmTimer = nil
    }
```

- [ ] **Step 6: Update handleRecordedEvent for adaptive mode validation**

In `handleRecordedEvent` (line 223), change the validity check (lines 240-242):

```swift
        // 检查事件有效性 (根据录制模式)
        let isValid: Bool
        switch recordingMode {
        case .singleKey:
            isValid = mosEvent.isRecordableAsSingleKey
        case .combination:
            isValid = mosEvent.isRecordable
        case .adaptive:
            isValid = mosEvent.isRecordableAsAdaptive
        }
```

And add adaptive state cleanup before the validity check:

```swift
        // Adaptive 模式: 清理定时器和状态
        if recordingMode == .adaptive {
            handleAdaptiveRecordedEvent(mosEvent)
        }
```

- [ ] **Step 7: Update stopRecording to clean adaptive state**

In `stopRecording()` (line 270), add after `cancelTimeoutTimer()` (line 279):

```swift
        // 清理 adaptive 定时器
        cancelAdaptiveConfirmTimer()
        cancelHoldConfirmTimer()
        adaptiveState = .idle
```

- [ ] **Step 8: Build and run existing tests**

Run: `xcodebuild test -scheme Debug -destination 'platform=macOS' 2>&1 | grep -E '(error:|Test Suite|Executed)' | tail -10`

Expected: BUILD SUCCEEDED, all existing tests pass.

- [ ] **Step 9: Commit**

```bash
git add Mos/Keys/KeyRecorder.swift Mos/InputEvent/MosInputEvent.swift
git commit -m "feat(recording): add .adaptive recording mode with timing-based intent detection"
```

---

### Task 6: Menu Integration — "自定义…" Menu Item

**Files:**
- Modify: `Mos/Shortcut/ShortcutManager.swift:117-138`
- Modify: `Mos/Localizable.xcstrings`

- [ ] **Step 1: Add "自定义…" menu item to ShortcutManager**

In `Mos/Shortcut/ShortcutManager.swift`, after the Logi actions block (after line 137, before the closing `}`), add:

```swift
        // 自定义绑定分隔线
        menu.addItem(NSMenuItem.separator())

        // "自定义…" 菜单项 (representedObject 为字符串标记)
        let customItem = NSMenuItem(
            title: NSLocalizedString("custom-shortcut", comment: ""),
            action: action,
            keyEquivalent: ""
        )
        customItem.target = target
        customItem.representedObject = "__custom__" as NSString
        if supportsSFSymbols {
            if #available(macOS 11.0, *) {
                customItem.image = createSymbolImage("keyboard")
            }
        }
        menu.addItem(customItem)
```

- [ ] **Step 2: Add localization key**

Add `"custom-shortcut"` key to `Mos/Localizable.xcstrings` with value `"自定义…"` for zh-Hans and `"Custom…"` for en. Use the xcstrings JSON format matching existing entries.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | grep -E '(error:|BUILD)' | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Mos/Shortcut/ShortcutManager.swift Mos/Localizable.xcstrings
git commit -m "feat(menu): add custom shortcut menu item to action popup"
```

---

### Task 7: UI Integration — ButtonTableCellView Custom Recording

**Files:**
- Modify: `Mos/Windows/PreferencesWindow/ButtonsView/ButtonTableCellView.swift`
- Modify: `Mos/Windows/PreferencesWindow/ButtonsView/PreferencesButtonsViewController.swift`

- [ ] **Step 1: Add custom recording callback and KeyRecorder to ButtonTableCellView**

In `ButtonTableCellView.swift`, add after line 24 (`onDeleteRequested`):

```swift
    private var onCustomShortcutRecorded: ((String) -> Void)?

    // MARK: - Custom Recording
    private lazy var customRecorder: KeyRecorder = {
        let recorder = KeyRecorder()
        recorder.delegate = self
        return recorder
    }()
```

- [ ] **Step 2: Update configure() to accept custom callback and clean recorder**

Change the `configure` method signature (line 31-35) to:

```swift
    func configure(
        with binding: ButtonBinding,
        onShortcutSelected: @escaping (SystemShortcut.Shortcut?) -> Void,
        onCustomShortcutRecorded: @escaping (String) -> Void,
        onDeleteRequested: @escaping () -> Void
    ) {
```

Add at the start of configure (after saving callbacks):

```swift
        self.onCustomShortcutRecorded = onCustomShortcutRecorded
        // 清理可能残留的录制状态 (cell 复用时)
        customRecorder.stopRecording()
```

And update the current shortcut display to handle custom bindings. Replace line 39:

```swift
        self.currentShortcut = binding.systemShortcut
```

with:

```swift
        self.currentShortcut = binding.systemShortcut
        self.currentCustomName = binding.isCustomBinding ? binding.systemShortcutName : nil
```

Add the property after `currentShortcut` (line 27):

```swift
    private var currentCustomName: String?
```

- [ ] **Step 3: Handle "__custom__" selection in shortcutSelected**

In `shortcutSelected(_:)` (line 265), add at the beginning before existing logic:

```swift
        // 自定义录制: 等菜单关闭后弹出录制弹窗
        if sender.representedObject as? String == "__custom__" {
            guard let menu = sender.menu else { return }
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
```

Add the `startCustomRecording` method:

```swift
    private func startCustomRecording() {
        customRecorder.startRecording(from: actionPopUpButton, mode: .adaptive)
    }
```

- [ ] **Step 4: Implement KeyRecorderDelegate on ButtonTableCellView**

Add extension at the end of the file:

```swift
// MARK: - KeyRecorderDelegate (Custom Recording)
extension ButtonTableCellView: KeyRecorderDelegate {
    func onEventRecorded(_ recorder: KeyRecorder, didRecordEvent event: MosInputEvent, isDuplicate: Bool) {
        guard !isDuplicate else { return }
        // 构造 custom:: 字符串
        let code = event.code
        let modifiers = UInt64(event.modifiers.rawValue)
        let customName = "custom::\(code):\(modifiers)"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.66) { [weak self] in
            guard let self = self else { return }
            // 更新本地显示
            self.currentShortcut = nil
            self.currentCustomName = customName
            self.updateCustomDisplay(event: event)
            // 通知外部
            self.onCustomShortcutRecorded?(customName)
        }
    }

    func validateRecordedEvent(_ recorder: KeyRecorder, event: MosInputEvent) -> Bool {
        // 检查自定义按键是否和现有绑定的 action 冲突 (不太可能但防万一)
        return true
    }
}
```

- [ ] **Step 4b: Clear currentCustomName on predefined/unbind selection**

In the existing `shortcutSelected(_:)` method, after the `__custom__` early return block, add at the start of the normal flow:

```swift
        // 清除自定义绑定状态
        self.currentCustomName = nil
}
```

- [ ] **Step 5: Add custom display update and adjustMenuStructure update**

Add display helper method:

```swift
    /// 更新 PopUpButton 显示为自定义绑定名称
    private func updateCustomDisplay(event: MosInputEvent) {
        let displayTitle = event.displayComponents.filter { $0 != "[Logi]" }.joined(separator: "+")
        var image: NSImage? = nil
        if #available(macOS 11.0, *) {
            image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        }
        setCustomTitle(displayTitle, image: image)
    }
```

Update `setupActionPopUpButton` (line 178-182) to handle custom bindings:

```swift
        // 设置当前选择
        if let shortcut = currentShortcut {
            selectShortcutInMenu(shortcut)
        } else if let customName = currentCustomName, customName.hasPrefix("custom::") {
            displayCustomBinding(customName)
        } else {
            setPlaceholderToUnbound()
        }
```

Add the `displayCustomBinding` method:

```swift
    /// 显示自定义绑定 (从 custom:: 字符串解析)
    private func displayCustomBinding(_ customName: String) {
        let parts = customName.dropFirst(8).split(separator: ":")
        guard parts.count == 2,
              let code = UInt16(parts[0]),
              let mods = UInt64(parts[1]) else {
            setPlaceholderToUnbound()
            return
        }
        // 构造显示组件 (复用 MosInputEvent.displayComponents 逻辑)
        var components: [String] = []
        let selfMask = KeyCode.getKeyMask(code).rawValue
        if mods & CGEventFlags.maskShift.rawValue != 0 && CGEventFlags.maskShift.rawValue & selfMask == 0 { components.append("⇧") }
        if mods & CGEventFlags.maskControl.rawValue != 0 && CGEventFlags.maskControl.rawValue & selfMask == 0 { components.append("⌃") }
        if mods & CGEventFlags.maskAlternate.rawValue != 0 && CGEventFlags.maskAlternate.rawValue & selfMask == 0 { components.append("⌥") }
        if mods & CGEventFlags.maskCommand.rawValue != 0 && CGEventFlags.maskCommand.rawValue & selfMask == 0 { components.append("⌘") }
        components.append(KeyCode.keyMap[code] ?? "Key(\(code))")

        let displayTitle = components.joined(separator: "+")
        var image: NSImage? = nil
        if #available(macOS 11.0, *) {
            image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        }
        setCustomTitle(displayTitle, image: image)
    }
```

Also update `adjustMenuStructure` to handle custom bindings:

```swift
    private func adjustMenuStructure(_ menu: NSMenu) {
        guard menu.items.count >= 3 else { return }

        let placeholderItem = menu.items[0]
        let firstSeparator = menu.items[1]
        let unboundItem = menu.items[2]

        let hasBoundAction = currentShortcut != nil || currentCustomName != nil

        if !hasBoundAction {
            placeholderItem.isHidden = true
            firstSeparator.isHidden = true
            unboundItem.title = NSLocalizedString("unbound", comment: "")
        } else {
            placeholderItem.isHidden = false
            firstSeparator.isHidden = false
            unboundItem.title = NSLocalizedString("unbind", comment: "")
        }
    }
```

- [ ] **Step 6: Update PreferencesButtonsViewController**

In `PreferencesButtonsViewController.swift`, add `updateButtonBinding(id:withCustomName:)` method (after `updateButtonBinding(id:with:)` around line 158):

```swift
    /// 更新按钮绑定 (自定义快捷键)
    func updateButtonBinding(id: UUID, withCustomName name: String) {
        guard let index = buttonBindings.firstIndex(where: { $0.id == id }) else { return }
        let old = buttonBindings[index]
        buttonBindings[index] = ButtonBinding(
            id: old.id,
            triggerEvent: old.triggerEvent,
            systemShortcutName: name,
            isEnabled: true,
            createdAt: old.createdAt
        )
        syncViewWithOptions()
    }
```

Update the cell configuration in `tableView(_:viewFor:)` (lines 186-194) to include the new callback:

```swift
            cell.configure(
                with: binding,
                onShortcutSelected: { [weak self] shortcut in
                    self?.updateButtonBinding(id: binding.id, with: shortcut)
                },
                onCustomShortcutRecorded: { [weak self] customName in
                    self?.updateButtonBinding(id: binding.id, withCustomName: customName)
                },
                onDeleteRequested: { [weak self] in
                    self?.removeButtonBinding(id: binding.id)
                }
            )
```

- [ ] **Step 7: Build to verify**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | grep -E '(error:|BUILD)' | tail -10`

Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add Mos/Windows/PreferencesWindow/ButtonsView/ButtonTableCellView.swift Mos/Windows/PreferencesWindow/ButtonsView/PreferencesButtonsViewController.swift
git commit -m "feat(ui): custom shortcut recording in ButtonTableCellView with menu timing"
```

---

### Task 8: CGEvent Extensions — MouseUp Recognition

**Files:**
- Modify: `Mos/Extension/CGEvent+Extensions.swift:144-151`

- [ ] **Step 1: Update isMouseEvent to recognize Up events**

In `Mos/Extension/CGEvent+Extensions.swift` line 144-151, change:

```swift
    var isMouseEvent: Bool {
        switch type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown,
                 .leftMouseUp, .rightMouseUp, .otherMouseUp:
                return true
            default:
                return false
        }
    }
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | grep -E '(error:|BUILD)' | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Mos/Extension/CGEvent+Extensions.swift
git commit -m "fix(extensions): recognize MouseUp event types in isMouseEvent"
```

---

### Task 9: Full Build & All Tests

**Files:** None (verification only)

- [ ] **Step 1: Full build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | grep -E '(error:|warning:|BUILD)' | tail -20`

Expected: BUILD SUCCEEDED, no new warnings

- [ ] **Step 2: Run all tests**

Run: `xcodebuild test -scheme Debug -destination 'platform=macOS' 2>&1 | grep -E '(Test Suite|Executed|FAIL)' | tail -20`

Expected: All test suites PASS

- [ ] **Step 3: Final commit (if any fixes needed)**

Only if previous steps required fixes.
