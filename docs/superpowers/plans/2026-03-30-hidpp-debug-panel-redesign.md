# HID++ Debug Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the HID++ debug panel with a modern IDE-style layout featuring NSVisualEffectView frosted glass theme, left sidebar device navigator, three-column info area, and expandable protocol log with raw packet sender.

**Architecture:** Single-file replacement of `LogitechHIDDebugPanel.swift`. Preserves existing data types (LogEntry, LogEntryType, HIDPPInfo) at file top, replaces the panel class entirely. Uses NSPanel + NSVisualEffectView following ToastPanel.swift pattern exactly. All layout is programmatic frame-based with autoresizingMask.

**Tech Stack:** Swift 4+, AppKit (NSPanel, NSVisualEffectView, NSOutlineView, NSTableView), IOKit HID, macOS 10.13+

**Spec:** `docs/superpowers/specs/2026-03-30-hidpp-debug-panel-redesign.md`

---

## File Map

All changes are in a single file:

- **Modify:** `Mos/LogitechHID/LogitechHIDDebugPanel.swift`
  - Lines 1-84: **Keep as-is** — LogEntryType enum, LogEntry struct, HIDPPInfo struct (data dictionaries)
  - Lines 86-791: **Replace entirely** — LogitechHIDDebugPanel class with new implementation

The existing `LogitechDeviceSession`, `LogitechHIDManager`, `LogitechCIDRegistry` files are **not modified**.

---

### Task 1: Enhanced LogEntry + Feature Action Registry

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (lines 13-30, add fields to LogEntry; add after HIDPPInfo)

- [ ] **Step 1: Add rawBytes and isExpanded to LogEntry**

In `LogitechHIDDebugPanel.swift`, replace the existing `LogEntry` struct (around line 24) with:

```swift
struct LogEntry {
    let timestamp: String
    let deviceName: String
    let type: LogEntryType
    let message: String
    let decoded: String?
    let rawBytes: [UInt8]?    // raw packet bytes for hex dump
    var isExpanded: Bool = false
}
```

- [ ] **Step 2: Add HIDPPFeatureActions registry after HIDPPInfo**

Insert this struct after the closing `}` of `HIDPPInfo` (after line ~84):

```swift
// MARK: - Feature Action Definitions

struct HIDPPFeatureAction {
    let name: String
    let functionId: UInt8
    enum ParamType { case none, index, hex }
    let paramType: ParamType
    let defaultParams: [UInt8]
}

struct HIDPPFeatureActions {
    static let knownActions: [UInt16: [HIDPPFeatureAction]] = [
        0x0000: [ // IRoot
            HIDPPFeatureAction(name: "Ping", functionId: 0x01, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetFeature", functionId: 0x00, paramType: .hex, defaultParams: [0x00, 0x01]),
        ],
        0x0001: [ // IFeatureSet
            HIDPPFeatureAction(name: "GetCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetFeatureID", functionId: 0x01, paramType: .index, defaultParams: []),
        ],
        0x0003: [ // DeviceFWVersion
            HIDPPFeatureAction(name: "GetEntityCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetFWVersion", functionId: 0x01, paramType: .index, defaultParams: []),
        ],
        0x0005: [ // DeviceNameType
            HIDPPFeatureAction(name: "GetCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetName", functionId: 0x01, paramType: .index, defaultParams: []),
            HIDPPFeatureAction(name: "GetType", functionId: 0x02, paramType: .none, defaultParams: []),
        ],
        0x1000: [ // BatteryStatus
            HIDPPFeatureAction(name: "GetLevel", functionId: 0x00, paramType: .none, defaultParams: []),
        ],
        0x1004: [ // UnifiedBattery
            HIDPPFeatureAction(name: "GetStatus", functionId: 0x00, paramType: .none, defaultParams: []),
        ],
        0x1B04: [ // ReprogControlsV4
            HIDPPFeatureAction(name: "GetCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetInfo", functionId: 0x01, paramType: .index, defaultParams: []),
            HIDPPFeatureAction(name: "GetReporting", functionId: 0x02, paramType: .hex, defaultParams: [0x00, 0x50]),
            HIDPPFeatureAction(name: "SetReporting", functionId: 0x03, paramType: .hex, defaultParams: [0x00, 0x50, 0x03]),
        ],
        0x2110: [ // SmartShift
            HIDPPFeatureAction(name: "GetStatus", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "SetStatus", functionId: 0x01, paramType: .hex, defaultParams: [0x02]),
        ],
        0x2121: [ // HiResWheel
            HIDPPFeatureAction(name: "GetCapability", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetMode", functionId: 0x01, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "SetMode", functionId: 0x02, paramType: .hex, defaultParams: [0x00]),
        ],
        0x2201: [ // AdjustableDPI
            HIDPPFeatureAction(name: "GetSensorCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetDPI", functionId: 0x01, paramType: .index, defaultParams: []),
            HIDPPFeatureAction(name: "SetDPI", functionId: 0x02, paramType: .hex, defaultParams: [0x00, 0x00, 0x03, 0x20]),
            HIDPPFeatureAction(name: "GetDPIList", functionId: 0x03, paramType: .index, defaultParams: []),
        ],
    ]

    static func actions(for featureId: UInt16) -> [HIDPPFeatureAction] {
        if let known = knownActions[featureId] { return known }
        // Generic function 0..7 for unknown features
        return (0...7).map { funcId in
            HIDPPFeatureAction(name: "Func \(funcId)", functionId: UInt8(funcId), paramType: .hex, defaultParams: [])
        }
    }
}
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): enhance LogEntry with rawBytes, add feature action registry"
```

---

### Task 2: Panel Shell — NSPanel + NSVisualEffectView + Layout Skeleton

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (replace class starting at ~line 86)

- [ ] **Step 1: Replace the class declaration and properties**

Delete everything from `// MARK: - Debug Panel` (line ~86) to end of file. Replace with the new class skeleton. This is a large replacement — the complete class shell with all properties, the `show()` method, `buildWindow()`, and `buildContent()` stub:

```swift
// MARK: - Debug Panel

class LogitechHIDDebugPanel: NSObject {

    static let shared = LogitechHIDDebugPanel()
    static let logNotification = NSNotification.Name("LogitechHIDDebugLog")

    // MARK: - Window
    private var window: NSPanel?

    // MARK: - Layout Constants
    private struct Layout {
        static let defaultWidth: CGFloat = 1100
        static let defaultHeight: CGFloat = 750
        static let minWidth: CGFloat = 1100
        static let minHeight: CGFloat = 600
        static let sidebarWidth: CGFloat = 180
        static let actionsWidth: CGFloat = 160
        static let sectionGap: CGFloat = 2
        static let padding: CGFloat = 8
        static let buttonHeight: CGFloat = 24
        static let buttonSpacing: CGFloat = 4
        static let filterChipSpacing: CGFloat = 4
        static let topAreaRatio: CGFloat = 0.4
        static let deviceInfoHeight: CGFloat = 140
        static let logToolbarHeight: CGFloat = 28
        static let rawInputHeight: CGFloat = 30
        static let sectionHeaderHeight: CGFloat = 20
    }

    // MARK: - Sidebar
    private var outlineView: NSOutlineView!
    private var deviceInfoLabels: [(key: NSTextField, value: NSTextField)] = []
    private var moreInfoLabels: [(key: NSTextField, value: NSTextField)] = []
    private var moreInfoContainer: NSView!
    private var moreInfoExpanded = false

    // MARK: - Tables
    private var featureTableView: NSTableView!
    private var controlsTableView: NSTableView!

    // MARK: - Actions Panel
    private var actionsContainer: NSView!
    private var contextActionsContainer: NSView!
    private var paramInputField: NSTextField?
    private var indexStepper: NSStepper?
    private var indexStepperLabel: NSTextField?

    // MARK: - Log
    private var logTableView: NSTableView!
    private var filterButtons: [LogEntryType: NSButton] = [:]
    private var rawInputField: NSTextField!
    private var reportTypeControl: NSSegmentedControl!

    // MARK: - State
    private var currentSession: LogitechDeviceSession?
    private var logTypeFilter: Set<LogEntryType> = Set(LogEntryType.allCases)
    static var logBuffer: [LogEntry] = []
    static let maxLogLines = 500
    private var logObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?

    // MARK: - Sidebar Data
    private struct DeviceNode {
        let session: LogitechDeviceSession
        var isReceiver: Bool { session.debugConnectionMode == "receiver" }
    }
    private var deviceNodes: [DeviceNode] = []

    // MARK: - Feature/Control Data
    private var featureRows: [(index: String, featureId: UInt16, featureIdHex: String, name: String)] = []
    private var controlRows: [ControlInfo] = []
    private var selectedFeatureId: UInt16?
    private var selectedControlCID: UInt16?

    // MARK: - Show / Hide

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshAll()
            startObserving()
            return
        }
        let w = buildWindow()
        window = w
        refreshAll()
        startObserving()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Logging API

    class func log(_ message: String) {
        let entry = LogEntry(timestamp: timestamp(), deviceName: "", type: .info, message: message, decoded: nil, rawBytes: nil)
        appendToBuffer(entry)
    }

    class func log(device: String, type: LogEntryType, message: String, decoded: String? = nil, rawBytes: [UInt8]? = nil) {
        let entry = LogEntry(timestamp: timestamp(), deviceName: device, type: type, message: message, decoded: decoded, rawBytes: rawBytes)
        appendToBuffer(entry)
    }

    private class func appendToBuffer(_ entry: LogEntry) {
        logBuffer.append(entry)
        if logBuffer.count > maxLogLines {
            logBuffer.removeFirst(logBuffer.count - maxLogLines)
        }
        NotificationCenter.default.post(name: logNotification, object: entry)
    }

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: Date())
    }
}
```

- [ ] **Step 2: Add buildWindow() following ToastPanel pattern**

Add after the logging API section:

```swift
    // MARK: - Build Window

    private func buildWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.defaultWidth, height: Layout.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Logitech HID++ Debug"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.minSize = NSSize(width: Layout.minWidth, height: Layout.minHeight)
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        effectView.autoresizingMask = [.width, .height]
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        if #available(macOS 10.14, *) {
            effectView.material = .hudWindow
            panel.appearance = NSAppearance(named: .vibrantDark)
        } else {
            effectView.material = .dark
        }
        panel.contentView = effectView

        let topInset = resolvedTopInset(for: panel)
        buildContent(in: effectView, topInset: topInset)

        return panel
    }

    private func resolvedTopInset(for panel: NSPanel) -> CGFloat {
        let titlebarHeight = panel.frame.height - panel.contentLayoutRect.height
        return max(Layout.padding, titlebarHeight + 4)
    }

    private func buildContent(in container: NSView, topInset: CGFloat) {
        let contentView = FlippedView(frame: container.bounds)
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)

        let sidebarX: CGFloat = 0
        let mainX: CGFloat = Layout.sidebarWidth + Layout.sectionGap
        let mainWidth = container.bounds.width - mainX
        let topAreaHeight = (container.bounds.height - topInset) * Layout.topAreaRatio
        let logY = topInset + topAreaHeight + Layout.sectionGap
        let logHeight = container.bounds.height - logY

        // Build sidebar
        buildSidebar(in: contentView, x: sidebarX, y: topInset,
                     width: Layout.sidebarWidth, height: container.bounds.height - topInset)

        // Build top three columns
        buildTopArea(in: contentView, x: mainX, y: topInset,
                     width: mainWidth, height: topAreaHeight)

        // Build protocol log
        buildLogArea(in: contentView, x: mainX, y: logY,
                     width: mainWidth, height: logHeight)
    }

    // Flipped coordinate view for top-down layout
    private final class FlippedView: NSView {
        override var isFlipped: Bool { return true }
    }
```

- [ ] **Step 3: Add placeholder build methods**

Add stub methods so the code compiles:

```swift
    // MARK: - Build Sidebar (placeholder)
    private func buildSidebar(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {}

    // MARK: - Build Top Area (placeholder)
    private func buildTopArea(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {}

    // MARK: - Build Log Area (placeholder)
    private func buildLogArea(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {}

    // MARK: - Refresh
    private func refreshAll() {}

    // MARK: - Observers
    private func startObserving() {}
    private func stopObserving() {}
```

- [ ] **Step 4: Add shared helpers**

```swift
    // MARK: - Helpers

    private func makeLabel(text: String, fontSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        label.textColor = color
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        return makeLabel(text: title, fontSize: 10, weight: .medium, color: .tertiaryLabelColor)
    }

    private func makeActionButton(title: String, action: Selector, color: NSColor = NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        btn.layer?.borderColor = color.withAlphaComponent(0.3).cgColor
        btn.layer?.borderWidth = 1
        btn.layer?.cornerRadius = 4
        btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        btn.contentTintColor = .labelColor
        return btn
    }

    private func makeSeparator() -> NSView {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.1).cgColor
        return sep
    }

    private func makeSectionBackground() -> NSView {
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.05).cgColor
        bg.layer?.cornerRadius = 6
        return bg
    }

    private func makeLogBackground() -> NSView {
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.4).cgColor
        bg.layer?.cornerRadius = 6
        return bg
    }
```

- [ ] **Step 5: Verify build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): panel shell with NSPanel + NSVisualEffectView"
```

---

### Task 3: Left Sidebar — Device Tree + Device Info

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (replace `buildSidebar` placeholder)

- [ ] **Step 1: Implement buildSidebar**

Replace the placeholder `buildSidebar` method:

```swift
    // MARK: - Build Sidebar

    private func buildSidebar(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let container = NSView(frame: NSRect(x: x, y: y, width: width, height: height))
        container.autoresizingMask = [.height]
        parent.addSubview(container)

        // Background
        let bg = makeSectionBackground()
        bg.frame = container.bounds
        bg.autoresizingMask = [.width, .height]
        container.addSubview(bg)

        var cy: CGFloat = Layout.padding

        // DEVICES header
        let header = makeSectionHeader("DEVICES")
        header.frame = NSRect(x: Layout.padding, y: cy, width: width - Layout.padding * 2, height: Layout.sectionHeaderHeight)
        container.addSubview(header)
        cy += Layout.sectionHeaderHeight

        // Outline view for device tree
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: cy, width: width,
                                                     height: height - cy - Layout.deviceInfoHeight - 1))
        scrollView.autoresizingMask = [.height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let outline = NSOutlineView()
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .sourceList
        outline.indentationPerLevel = 14
        outline.rowHeight = 22

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.action = #selector(outlineViewClicked(_:))

        scrollView.documentView = outline
        container.addSubview(scrollView)
        self.outlineView = outline

        // Separator
        let sep = makeSeparator()
        sep.frame = NSRect(x: Layout.padding, y: height - Layout.deviceInfoHeight - 1,
                           width: width - Layout.padding * 2, height: 1)
        sep.autoresizingMask = [.minYMargin]
        container.addSubview(sep)

        // Device info area
        buildDeviceInfoArea(in: container, y: height - Layout.deviceInfoHeight, width: width, height: Layout.deviceInfoHeight)
    }

    private func buildDeviceInfoArea(in parent: NSView, y: CGFloat, width: CGFloat, height: CGFloat) {
        let infoContainer = NSView(frame: NSRect(x: 0, y: y, width: width, height: height))
        infoContainer.autoresizingMask = [.minYMargin]
        parent.addSubview(infoContainer)

        let keys = ["VID", "PID", "Protocol", "Transport", "Dev Index", "Conn Mode", "Opened"]
        var iy: CGFloat = Layout.padding
        let keyW: CGFloat = 65
        let valX: CGFloat = keyW + 4

        deviceInfoLabels.removeAll()
        for keyText in keys {
            let keyLabel = makeLabel(text: keyText, fontSize: 9, weight: .medium, color: .tertiaryLabelColor)
            keyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            keyLabel.frame = NSRect(x: Layout.padding, y: iy, width: keyW, height: 14)
            infoContainer.addSubview(keyLabel)

            let valLabel = makeLabel(text: "--", fontSize: 9, color: .secondaryLabelColor)
            valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            valLabel.frame = NSRect(x: valX, y: iy, width: width - valX - Layout.padding, height: 14)
            infoContainer.addSubview(valLabel)

            deviceInfoLabels.append((key: keyLabel, value: valLabel))
            iy += 16
        }

        // More... toggle
        let moreBtn = NSButton(title: "More...", target: self, action: #selector(toggleMoreInfo))
        moreBtn.isBordered = false
        moreBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        moreBtn.contentTintColor = NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        moreBtn.frame = NSRect(x: Layout.padding, y: iy, width: 60, height: 14)
        infoContainer.addSubview(moreBtn)
        iy += 16

        // More info container (hidden by default)
        let moreContainer = NSView(frame: NSRect(x: 0, y: iy, width: width, height: 80))
        moreContainer.isHidden = true
        infoContainer.addSubview(moreContainer)
        self.moreInfoContainer = moreContainer

        let moreKeys = ["Usage Page", "Usage", "HID++ Cand", "Init Done", "Dvrt CIDs"]
        var my: CGFloat = 0
        moreInfoLabels.removeAll()
        for keyText in moreKeys {
            let keyLabel = makeLabel(text: keyText, fontSize: 9, weight: .medium, color: .tertiaryLabelColor)
            keyLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            keyLabel.frame = NSRect(x: Layout.padding, y: my, width: keyW, height: 14)
            moreContainer.addSubview(keyLabel)

            let valLabel = makeLabel(text: "--", fontSize: 9, color: .secondaryLabelColor)
            valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            valLabel.frame = NSRect(x: valX, y: my, width: width - valX - Layout.padding, height: 14)
            moreContainer.addSubview(valLabel)

            moreInfoLabels.append((key: keyLabel, value: valLabel))
            my += 16
        }
    }

    @objc private func toggleMoreInfo() {
        moreInfoExpanded = !moreInfoExpanded
        moreInfoContainer?.isHidden = !moreInfoExpanded
    }

    @objc private func outlineViewClicked(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)

        if let node = item as? DeviceNode {
            currentSession = node.session
            refreshRightPanels()
        } else if let slotInfo = item as? (session: LogitechDeviceSession, slot: UInt8) {
            currentSession = slotInfo.session
            slotInfo.session.setTargetSlot(slot: slotInfo.slot)
            // Show discovering state, then call rediscover
            refreshRightPanelsLoading()
            slotInfo.session.rediscoverFeatures()
        }
    }
```

- [ ] **Step 2: Add NSOutlineViewDataSource + Delegate conformance**

Add at the end of the file, as extensions:

```swift
// MARK: - NSOutlineViewDataSource & Delegate

extension LogitechHIDDebugPanel: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return deviceNodes.count }
        if let node = item as? DeviceNode, node.isReceiver {
            return node.session.debugReceiverPairedDevices.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return deviceNodes[index] }
        if let node = item as? DeviceNode, node.isReceiver {
            let paired = node.session.debugReceiverPairedDevices[index]
            return (session: node.session, slot: paired.slot)
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? DeviceNode { return node.isReceiver }
        return false
    }
}

extension LogitechHIDDebugPanel: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cellId = NSUserInterfaceItemIdentifier("DeviceCell")
        let cell = outlineView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.font = NSFont.systemFont(ofSize: 11)
        cell.backgroundColor = .clear
        cell.isBezeled = false
        cell.isEditable = false

        if let node = item as? DeviceNode {
            let prefix = node.isReceiver ? "[R]" : "[M]"
            let status = "\u{25CF}"  // filled circle
            cell.stringValue = "\(prefix) \(node.session.deviceInfo.name)"
            cell.textColor = .labelColor
            // Append green dot
            let attributed = NSMutableAttributedString(string: "\(prefix) \(node.session.deviceInfo.name) ")
            let dot = NSAttributedString(string: status, attributes: [
                .foregroundColor: NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 8)
            ])
            attributed.append(dot)
            cell.attributedStringValue = attributed
        } else if let slotInfo = item as? (session: LogitechDeviceSession, slot: UInt8) {
            let paired = slotInfo.session.debugReceiverPairedDevices
            let slotIdx = Int(slotInfo.slot) - 1
            guard slotIdx >= 0, slotIdx < paired.count else {
                cell.stringValue = "Slot \(slotInfo.slot): --"
                cell.textColor = .tertiaryLabelColor
                return cell
            }
            let dev = paired[slotIdx]
            if dev.isConnected {
                cell.stringValue = "\(dev.name.isEmpty ? "Slot \(dev.slot)" : dev.name)"
                cell.textColor = .labelColor
            } else {
                cell.stringValue = "Slot \(dev.slot): empty"
                cell.textColor = .tertiaryLabelColor
            }
        }
        return cell
    }
}
```

- [ ] **Step 3: Add refreshSidebar and refreshDeviceInfo methods**

```swift
    // MARK: - Refresh Sidebar

    private func refreshSidebar() {
        let sessions = LogitechHIDManager.shared.activeSessions
        deviceNodes = sessions
            .filter { $0.debugConnectionMode != "unsupported" }
            .map { DeviceNode(session: $0) }
        outlineView?.reloadData()

        // Auto-expand receivers
        for node in deviceNodes where node.isReceiver {
            outlineView?.expandItem(node)
        }

        // Auto-select first if no selection
        if currentSession == nil, let first = deviceNodes.first {
            currentSession = first.session
        }
    }

    private func refreshDeviceInfo() {
        guard let session = currentSession else {
            for pair in deviceInfoLabels { pair.value.stringValue = "--" }
            for pair in moreInfoLabels { pair.value.stringValue = "--" }
            return
        }
        let info = session.deviceInfo
        let values: [String] = [
            String(format: "0x%04X", info.vendorId),
            String(format: "0x%04X", info.productId),
            session.debugFeatureIndex.isEmpty ? "--" : "4.x",
            session.transport,
            String(format: "0x%02X", session.debugDeviceIndex),
            session.debugConnectionMode,
            session.debugDeviceOpened ? "\u{2713}" : "\u{2717}",
        ]
        for (i, val) in values.enumerated() where i < deviceInfoLabels.count {
            deviceInfoLabels[i].value.stringValue = val
        }

        let moreValues: [String] = [
            String(format: "0x%04X", session.usagePage),
            String(format: "0x%04X", session.usage),
            session.isHIDPPCandidate ? "Yes" : "No",
            session.debugReprogInitComplete ? "Yes" : "No",
            "\(session.debugDivertedCIDs.count)",
        ]
        for (i, val) in moreValues.enumerated() where i < moreInfoLabels.count {
            moreInfoLabels[i].value.stringValue = val
        }
    }
```

- [ ] **Step 4: Verify build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): left sidebar with device tree and device info"
```

---

### Task 4: Top Area — Features Table + Controls Table + Actions Panel

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (replace `buildTopArea` placeholder)

- [ ] **Step 1: Implement buildTopArea with three columns**

Replace the `buildTopArea` placeholder:

```swift
    // MARK: - Build Top Area

    private func buildTopArea(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let container = NSView(frame: NSRect(x: x, y: y, width: width, height: height))
        container.autoresizingMask = [.width]
        parent.addSubview(container)

        let actionsX = width - Layout.actionsWidth
        let tableAreaWidth = actionsX - Layout.sectionGap
        let halfTableWidth = (tableAreaWidth - Layout.sectionGap) / 2

        // Features table (left)
        buildFeatureTable(in: container, x: 0, y: 0, width: halfTableWidth, height: height)

        // Controls table (middle)
        buildControlsTable(in: container, x: halfTableWidth + Layout.sectionGap, y: 0,
                           width: halfTableWidth, height: height)

        // Actions panel (right)
        buildActionsPanel(in: container, x: actionsX, y: 0,
                          width: Layout.actionsWidth, height: height)
    }

    // MARK: - Features Table

    private func buildFeatureTable(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let bg = makeSectionBackground()
        bg.frame = NSRect(x: x, y: y, width: width, height: height)
        bg.autoresizingMask = [.width]
        parent.addSubview(bg)

        let header = makeSectionHeader("FEATURES (0)")
        header.frame = NSRect(x: x + Layout.padding, y: y + 4, width: width - Layout.padding * 2, height: 16)
        header.tag = 100  // Tag for dynamic update
        parent.addSubview(header)

        let tableY = y + Layout.sectionHeaderHeight
        let scrollView = NSScrollView(frame: NSRect(x: x, y: tableY, width: width, height: height - Layout.sectionHeaderHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let table = NSTableView()
        table.backgroundColor = .clear
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.rowHeight = 20
        table.tag = 200  // Features table tag
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(featureTableClicked(_:))

        let colIdx = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fIdx"))
        colIdx.width = 36
        colIdx.title = "Idx"
        table.addTableColumn(colIdx)

        let colId = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fId"))
        colId.width = 50
        colId.title = "ID"
        table.addTableColumn(colId)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fName"))
        colName.resizingMask = .autoresizingMask
        colName.title = "Name"
        table.addTableColumn(colName)

        scrollView.documentView = table
        parent.addSubview(scrollView)
        self.featureTableView = table
    }

    // MARK: - Controls Table

    private func buildControlsTable(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let bg = makeSectionBackground()
        bg.frame = NSRect(x: x, y: y, width: width, height: height)
        bg.autoresizingMask = [.width]
        parent.addSubview(bg)

        let header = makeSectionHeader("CONTROLS (0)")
        header.frame = NSRect(x: x + Layout.padding, y: y + 4, width: width - Layout.padding * 2, height: 16)
        header.tag = 101  // Tag for dynamic update
        parent.addSubview(header)

        let tableY = y + Layout.sectionHeaderHeight
        let scrollView = NSScrollView(frame: NSRect(x: x, y: tableY, width: width, height: height - Layout.sectionHeaderHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let table = NSTableView()
        table.backgroundColor = .clear
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.rowHeight = 20
        table.tag = 201  // Controls table tag
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(controlsTableClicked(_:))

        let colCid = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cCid"))
        colCid.width = 50
        table.addTableColumn(colCid)

        let colName = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cName"))
        colName.resizingMask = .autoresizingMask
        table.addTableColumn(colName)

        let colStatus = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cStatus"))
        colStatus.width = 50
        table.addTableColumn(colStatus)

        scrollView.documentView = table
        parent.addSubview(scrollView)
        self.controlsTableView = table
    }

    // MARK: - Actions Panel

    private func buildActionsPanel(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let bg = makeSectionBackground()
        bg.frame = NSRect(x: x, y: y, width: width, height: height)
        parent.addSubview(bg)

        let header = makeSectionHeader("ACTIONS")
        header.frame = NSRect(x: x + Layout.padding, y: y + 4, width: width - Layout.padding * 2, height: 16)
        parent.addSubview(header)

        // Context actions area (dynamic, top portion)
        let ctxY = y + Layout.sectionHeaderHeight
        let ctxHeight = height - Layout.sectionHeaderHeight - 200  // Reserve bottom for global actions
        let ctxContainer = NSView(frame: NSRect(x: x, y: ctxY, width: width, height: max(ctxHeight, 60)))
        ctxContainer.autoresizingMask = []
        parent.addSubview(ctxContainer)
        self.contextActionsContainer = ctxContainer

        // Placeholder text
        let placeholder = makeLabel(text: "Select a feature\nor control", fontSize: 10, color: .tertiaryLabelColor)
        placeholder.frame = NSRect(x: Layout.padding, y: Layout.padding, width: width - Layout.padding * 2, height: 40)
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 2
        ctxContainer.addSubview(placeholder)

        // Separator
        let sep = makeSeparator()
        let sepY = y + height - 200
        sep.frame = NSRect(x: x + Layout.padding, y: sepY, width: width - Layout.padding * 2, height: 1)
        parent.addSubview(sep)

        // Global actions area
        let globalY = sepY + Layout.padding
        let globalContainer = NSView(frame: NSRect(x: x, y: globalY, width: width, height: 190))
        parent.addSubview(globalContainer)
        self.actionsContainer = globalContainer

        let btnW = width - Layout.padding * 2
        var by: CGFloat = 0

        let globalActions: [(String, Selector)] = [
            ("Re-Discover", #selector(rediscoverClicked)),
            ("Re-Divert", #selector(redivertClicked)),
            ("Undivert All", #selector(undivertClicked)),
            ("Enumerate", #selector(enumerateClicked)),
            ("Clear Log", #selector(clearLogClicked)),
        ]

        for (title, action) in globalActions {
            let btn = makeActionButton(title: title, action: action)
            btn.frame = NSRect(x: Layout.padding, y: by, width: btnW, height: Layout.buttonHeight)
            globalContainer.addSubview(btn)
            by += Layout.buttonHeight + Layout.buttonSpacing
        }
    }
```

- [ ] **Step 2: Add table click handlers and context actions updater**

```swift
    @objc private func featureTableClicked(_ sender: Any?) {
        let row = featureTableView.selectedRow
        controlsTableView?.deselectAll(nil)
        selectedControlCID = nil
        guard row >= 0, row < featureRows.count else {
            selectedFeatureId = nil
            updateContextActions()
            return
        }
        selectedFeatureId = featureRows[row].featureId
        updateContextActions()
    }

    @objc private func controlsTableClicked(_ sender: Any?) {
        let row = controlsTableView.selectedRow
        featureTableView?.deselectAll(nil)
        selectedFeatureId = nil
        guard row >= 0, row < controlRows.count else {
            selectedControlCID = nil
            updateContextActions()
            return
        }
        selectedControlCID = controlRows[row].cid
        updateContextActions()
    }

    private func updateContextActions() {
        guard let container = contextActionsContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        let w = container.bounds.width - Layout.padding * 2
        var by: CGFloat = 0

        if let featureId = selectedFeatureId, let session = currentSession {
            let actions = HIDPPFeatureActions.actions(for: featureId)
            for action in actions {
                let btn = makeActionButton(title: action.name, action: #selector(featureActionClicked(_:)))
                btn.tag = Int(action.functionId)
                btn.frame = NSRect(x: Layout.padding, y: by, width: w, height: Layout.buttonHeight)
                container.addSubview(btn)
                by += Layout.buttonHeight + Layout.buttonSpacing
            }

            // Param input field for hex-param actions
            by += 4
            let paramField = NSTextField()
            paramField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            paramField.placeholderString = "params (hex)"
            paramField.frame = NSRect(x: Layout.padding, y: by, width: w, height: 22)
            paramField.wantsLayer = true
            paramField.layer?.cornerRadius = 3
            paramField.textColor = .labelColor
            paramField.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.08)
            paramField.isBezeled = false
            container.addSubview(paramField)
            self.paramInputField = paramField
            by += 26

            // Index stepper for index-param actions
            let stepperLabel = makeLabel(text: "Index: 0", fontSize: 10, color: .secondaryLabelColor)
            stepperLabel.frame = NSRect(x: Layout.padding, y: by, width: 60, height: 18)
            container.addSubview(stepperLabel)
            self.indexStepperLabel = stepperLabel

            let stepper = NSStepper()
            stepper.minValue = 0
            stepper.maxValue = 255
            stepper.integerValue = 0
            stepper.target = self
            stepper.action = #selector(indexStepperChanged(_:))
            stepper.frame = NSRect(x: Layout.padding + 62, y: by, width: 19, height: 18)
            container.addSubview(stepper)
            self.indexStepper = stepper

        } else if let cid = selectedControlCID {
            let isDiverted = currentSession?.debugDivertedCIDs.contains(cid) ?? false
            let divertTitle = isDiverted ? "Undivert" : "Divert"
            let divertBtn = makeActionButton(title: divertTitle, action: #selector(toggleDivertClicked))
            divertBtn.frame = NSRect(x: Layout.padding, y: by, width: w, height: Layout.buttonHeight)
            container.addSubview(divertBtn)
            by += Layout.buttonHeight + Layout.buttonSpacing

            let queryBtn = makeActionButton(title: "Query Reporting", action: #selector(queryReportingClicked))
            queryBtn.frame = NSRect(x: Layout.padding, y: by, width: w, height: Layout.buttonHeight)
            container.addSubview(queryBtn)
        } else {
            let placeholder = makeLabel(text: "Select a feature\nor control", fontSize: 10, color: .tertiaryLabelColor)
            placeholder.frame = NSRect(x: Layout.padding, y: Layout.padding,
                                       width: w, height: 40)
            placeholder.alignment = .center
            placeholder.maximumNumberOfLines = 2
            container.addSubview(placeholder)
        }
    }

    @objc private func indexStepperChanged(_ sender: NSStepper) {
        indexStepperLabel?.stringValue = "Index: \(sender.integerValue)"
    }
```

- [ ] **Step 3: Add action button handlers**

```swift
    // MARK: - Global Actions

    @objc private func rediscoverClicked() {
        currentSession?.rediscoverFeatures()
        refreshRightPanelsLoading()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.refreshRightPanels()
        }
    }

    @objc private func redivertClicked() {
        currentSession?.redivertAllControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshControls()
        }
    }

    @objc private func undivertClicked() {
        currentSession?.undivertAllControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshControls()
        }
    }

    @objc private func enumerateClicked() {
        currentSession?.enumerateReceiverDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.refreshSidebar()
            self?.refreshRightPanels()
        }
    }

    @objc private func clearLogClicked() {
        LogitechHIDDebugPanel.logBuffer.removeAll()
        logTableView?.reloadData()
    }

    // MARK: - Feature Actions

    @objc private func featureActionClicked(_ sender: NSButton) {
        guard let session = currentSession, let featureId = selectedFeatureId else { return }
        guard let featureIdx = session.debugFeatureIndex[featureId] else {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .warning, message: "Feature 0x\(String(format: "%04X", featureId)) not indexed")
            return
        }

        let functionId = UInt8(sender.tag)
        var params = [UInt8](repeating: 0, count: 16)

        // Check for param input
        let actions = HIDPPFeatureActions.actions(for: featureId)
        if let action = actions.first(where: { $0.functionId == functionId }) {
            switch action.paramType {
            case .none:
                break
            case .index:
                let idx = UInt8(indexStepper?.integerValue ?? 0)
                params[0] = idx
            case .hex:
                if let hexStr = paramInputField?.stringValue, !hexStr.isEmpty {
                    let bytes = hexStr.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                    for (i, b) in bytes.prefix(16).enumerated() { params[i] = b }
                } else {
                    for (i, b) in action.defaultParams.prefix(16).enumerated() { params[i] = b }
                }
            }
        }

        // Build and send raw HID++ 2.0 long report
        sendDebugPacket(session: session, featureIndex: featureIdx, functionId: functionId, params: params)
    }

    @objc private func toggleDivertClicked() {
        guard let session = currentSession, let cid = selectedControlCID else { return }
        session.toggleDivert(cid: cid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshControls()
            self?.updateContextActions()
        }
    }

    @objc private func queryReportingClicked() {
        guard let session = currentSession, let cid = selectedControlCID else { return }
        guard let reprogIdx = session.debugFeatureIndex[0x1B04] else { return }
        let params: [UInt8] = [UInt8(cid >> 8), UInt8(cid & 0xFF)] + [UInt8](repeating: 0, count: 14)
        sendDebugPacket(session: session, featureIndex: reprogIdx, functionId: 2, params: params)
    }

    // MARK: - Raw Packet Sender

    private func sendDebugPacket(session: LogitechDeviceSession, featureIndex: UInt8, functionId: UInt8, params: [UInt8]) {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = 0x11  // long report
        report[1] = session.debugDeviceIndex
        report[2] = featureIndex
        report[3] = (functionId << 4) | 0x01
        for (i, p) in params.prefix(16).enumerated() { report[4 + i] = p }

        let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .tx, message: "TX: \(hex)", rawBytes: report)

        let result = IOHIDDeviceSetReport(session.hidDevice, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
        if result != kIOReturnSuccess {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .error,
                                      message: "IOHIDDeviceSetReport failed: \(String(format: "0x%08X", result))")
        }
    }
```

- [ ] **Step 4: Verify build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): features/controls tables and actions panel"
```

---

### Task 5: Protocol Log — NSTableView + Filtering + Expand/Collapse

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (replace `buildLogArea` placeholder)

- [ ] **Step 1: Implement buildLogArea**

Replace the `buildLogArea` placeholder:

```swift
    // MARK: - Build Log Area

    private func buildLogArea(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let bg = makeLogBackground()
        bg.frame = NSRect(x: x, y: y, width: width, height: height)
        bg.autoresizingMask = [.width, .height]
        parent.addSubview(bg)

        var cy = y + 4

        // Toolbar row
        let toolbarContainer = NSView(frame: NSRect(x: x, y: cy, width: width, height: Layout.logToolbarHeight))
        toolbarContainer.autoresizingMask = [.width]
        parent.addSubview(toolbarContainer)

        // Label
        let logLabel = makeSectionHeader("PROTOCOL LOG")
        logLabel.frame = NSRect(x: Layout.padding, y: 6, width: 100, height: 16)
        toolbarContainer.addSubview(logLabel)

        // Filter chips
        var fx: CGFloat = 110
        let chipColors: [LogEntryType: NSColor] = [
            .tx: NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0),
            .rx: NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0),
            .error: NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1.0),
            .buttonEvent: NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0),
            .warning: NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.2, alpha: 1.0),
            .info: NSColor(calibratedWhite: 0.75, alpha: 1.0),
        ]
        let chipLabels: [LogEntryType: String] = [
            .tx: "TX", .rx: "RX", .error: "ERR",
            .buttonEvent: "BTN", .warning: "WARN", .info: "INFO",
        ]
        let chipOrder: [LogEntryType] = [.tx, .rx, .error, .buttonEvent, .warning, .info]

        for entryType in chipOrder {
            let chipLabel = chipLabels[entryType] ?? entryType.rawValue
            let chipColor = chipColors[entryType] ?? .gray
            let btn = NSButton(title: chipLabel, target: self, action: #selector(filterChipClicked(_:)))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.backgroundColor = chipColor.withAlphaComponent(0.3).cgColor
            btn.layer?.cornerRadius = 3
            btn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            btn.contentTintColor = chipColor
            btn.tag = chipOrder.firstIndex(of: entryType) ?? 0
            btn.frame = NSRect(x: fx, y: 4, width: 38, height: 20)
            toolbarContainer.addSubview(btn)
            filterButtons[entryType] = btn
            fx += 42
        }

        // Export and Clear buttons (right aligned)
        let clearBtn = makeActionButton(title: "Clear", action: #selector(clearLogClicked))
        clearBtn.frame = NSRect(x: width - 50, y: 4, width: 42, height: 20)
        clearBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        toolbarContainer.addSubview(clearBtn)

        let exportBtn = makeActionButton(title: "Export", action: #selector(exportLogClicked))
        exportBtn.frame = NSRect(x: width - 100, y: 4, width: 46, height: 20)
        exportBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        toolbarContainer.addSubview(exportBtn)

        cy += Layout.logToolbarHeight

        // Log table
        let tableHeight = height - Layout.logToolbarHeight - Layout.rawInputHeight - 8
        let scrollView = NSScrollView(frame: NSRect(x: x, y: cy, width: width, height: tableHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let table = NSTableView()
        table.backgroundColor = .clear
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.rowHeight = 18
        table.tag = 300  // Log table tag
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(logRowClicked(_:))

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("log"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        scrollView.documentView = table
        parent.addSubview(scrollView)
        self.logTableView = table

        cy += tableHeight + 4

        // Raw input bar
        buildRawInputBar(in: parent, x: x, y: cy, width: width)
    }

    private func buildRawInputBar(in parent: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        let container = NSView(frame: NSRect(x: x, y: y, width: width, height: Layout.rawInputHeight))
        container.autoresizingMask = [.width, .minYMargin]
        parent.addSubview(container)

        // Separator
        let sep = makeSeparator()
        sep.frame = NSRect(x: Layout.padding, y: 0, width: width - Layout.padding * 2, height: 1)
        sep.autoresizingMask = [.width]
        container.addSubview(sep)

        // RAW: label
        let rawLabel = makeLabel(text: "RAW:", fontSize: 10, weight: .medium, color: .tertiaryLabelColor)
        rawLabel.frame = NSRect(x: Layout.padding, y: 6, width: 35, height: 18)
        container.addSubview(rawLabel)

        // Report type selector
        let segCtrl = NSSegmentedControl(labels: ["Short 7B", "Long 20B"], trackingMode: .selectOne, target: nil, action: nil)
        segCtrl.selectedSegment = 1  // Default to Long
        segCtrl.frame = NSRect(x: 48, y: 5, width: 120, height: 20)
        segCtrl.font = NSFont.systemFont(ofSize: 9)
        container.addSubview(segCtrl)
        self.reportTypeControl = segCtrl

        // Hex input field
        let inputField = NSTextField()
        inputField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        inputField.placeholderString = "11 FF 00 01 1B 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
        inputField.frame = NSRect(x: 174, y: 5, width: width - 174 - 56, height: 20)
        inputField.wantsLayer = true
        inputField.layer?.cornerRadius = 3
        inputField.textColor = .labelColor
        inputField.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.06)
        inputField.isBezeled = false
        inputField.autoresizingMask = [.width]
        container.addSubview(inputField)
        self.rawInputField = inputField

        // Send button
        let sendBtn = makeActionButton(title: "Send", action: #selector(sendRawClicked),
                                       color: NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0))
        sendBtn.frame = NSRect(x: width - 50, y: 5, width: 42, height: 20)
        sendBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        sendBtn.autoresizingMask = [.minXMargin]
        container.addSubview(sendBtn)
    }
```

- [ ] **Step 2: Add log action handlers**

```swift
    // MARK: - Log Actions

    @objc private func filterChipClicked(_ sender: NSButton) {
        let chipOrder: [LogEntryType] = [.tx, .rx, .error, .buttonEvent, .warning, .info]
        guard sender.tag >= 0, sender.tag < chipOrder.count else { return }
        let type = chipOrder[sender.tag]

        if logTypeFilter.contains(type) {
            logTypeFilter.remove(type)
            sender.layer?.opacity = 0.3
        } else {
            logTypeFilter.insert(type)
            sender.layer?.opacity = 1.0
        }
        logTableView?.reloadData()
    }

    @objc private func logRowClicked(_ sender: Any?) {
        let row = logTableView.clickedRow
        let filtered = filteredLogEntries()
        guard row >= 0, row < filtered.count else { return }
        let bufferIdx = filtered[row].0
        LogitechHIDDebugPanel.logBuffer[bufferIdx].isExpanded.toggle()
        logTableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        logTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func exportLogClicked() {
        let panel = NSSavePanel()
        let dateStr: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd-HHmmss"
            return fmt.string(from: Date())
        }()
        panel.nameFieldStringValue = "hidpp-debug-\(dateStr).log"
        panel.allowedFileTypes = ["log", "txt"]
        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            var output = ""
            for entry in LogitechHIDDebugPanel.logBuffer {
                let device = entry.deviceName.isEmpty ? "" : "[\(entry.deviceName)] "
                output += "[\(entry.timestamp)] \(device)[\(entry.type.rawValue)] \(entry.message)\n"
                if let decoded = entry.decoded { output += "  > \(decoded)\n" }
                if let raw = entry.rawBytes {
                    let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
                    output += "  HEX: \(hex)\n"
                }
            }
            try? output.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func sendRawClicked() {
        guard let session = currentSession else { return }
        guard session.debugDeviceOpened else {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .warning, message: "Device not opened")
            return
        }

        let hexStr = rawInputField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !hexStr.isEmpty else { return }

        let bytes = hexStr.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty else {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .warning, message: "Invalid hex input")
            return
        }

        let isLong = reportTypeControl.selectedSegment == 1
        let reportLen = isLong ? 20 : 7
        var report = [UInt8](repeating: 0, count: reportLen)
        report[0] = isLong ? 0x11 : 0x10
        // Copy user bytes (skip reportId if user provided it)
        let srcBytes: [UInt8]
        if bytes.first == 0x10 || bytes.first == 0x11 {
            srcBytes = Array(bytes.dropFirst())
        } else {
            srcBytes = bytes
        }
        for (i, b) in srcBytes.prefix(reportLen - 1).enumerated() {
            report[1 + i] = b
        }

        let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .tx, message: "TX: \(hex)", rawBytes: report)

        let result = IOHIDDeviceSetReport(session.hidDevice, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
        if result != kIOReturnSuccess {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .error,
                                      message: "IOHIDDeviceSetReport failed: \(String(format: "0x%08X", result))")
        }
    }

    private func filteredLogEntries() -> [(Int, LogEntry)] {
        return LogitechHIDDebugPanel.logBuffer.enumerated().filter { logTypeFilter.contains($0.element.type) }
    }
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): protocol log with filtering, expand/collapse, raw sender"
```

---

### Task 6: NSTableView Delegate/DataSource for Features, Controls, and Log Tables

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (add table delegate/datasource)

- [ ] **Step 1: Add NSTableViewDataSource + Delegate extension**

```swift
// MARK: - NSTableViewDataSource & Delegate

extension LogitechHIDDebugPanel: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case 200: return featureRows.count
        case 201: return controlRows.count
        case 300: return filteredLogEntries().count
        default: return 0
        }
    }
}

extension LogitechHIDDebugPanel: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch tableView.tag {
        case 200: return featureCell(tableColumn: tableColumn, row: row)
        case 201: return controlCell(tableColumn: tableColumn, row: row)
        case 300: return logCell(row: row)
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView.tag == 300 {
            let filtered = filteredLogEntries()
            guard row < filtered.count else { return 18 }
            let entry = filtered[row].1
            if entry.isExpanded {
                var lines = 1  // summary
                if entry.rawBytes != nil { lines += 1 }  // hex dump
                if entry.decoded != nil { lines += 1 }  // decoded
                return CGFloat(lines) * 16 + 4
            }
        }
        return tableView.tag == 300 ? 18 : 20
    }

    // MARK: - Feature Cell

    private func featureCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < featureRows.count else { return nil }
        let item = featureRows[row]
        let cellId = NSUserInterfaceItemIdentifier("fCell")
        let cell = featureTableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cell.backgroundColor = .clear
        cell.isBezeled = false
        cell.isEditable = false

        switch tableColumn?.identifier.rawValue {
        case "fIdx": cell.stringValue = item.index
        case "fId": cell.stringValue = item.featureIdHex
        case "fName":
            cell.stringValue = item.name
            cell.textColor = NSColor(calibratedRed: 0.5, green: 0.7, blue: 1.0, alpha: 1.0)
        default: break
        }
        return cell
    }

    // MARK: - Control Cell

    private func controlCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < controlRows.count else { return nil }
        let ctrl = controlRows[row]
        let cellId = NSUserInterfaceItemIdentifier("cCell")
        let cell = controlsTableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cell.backgroundColor = .clear
        cell.isBezeled = false
        cell.isEditable = false

        let isDiverted = ctrl.reportingFlags & 0x01 != 0
        let isRemapped = ctrl.targetCID != 0

        switch tableColumn?.identifier.rawValue {
        case "cCid": cell.stringValue = String(format: "0x%04X", ctrl.cid)
        case "cName":
            cell.stringValue = LogitechCIDRegistry.name(for: ctrl.cid)
            cell.textColor = .labelColor
        case "cStatus":
            if isDiverted {
                cell.stringValue = "DVRT"
                cell.textColor = NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.0, alpha: 0.8)
            } else if isRemapped {
                cell.stringValue = "REMAP"
                cell.textColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 0.8)
            } else {
                cell.stringValue = "\u{25CF}"
                cell.textColor = NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
            }
        default: break
        }
        return cell
    }

    // MARK: - Log Cell

    private func logCell(row: Int) -> NSView? {
        let filtered = filteredLogEntries()
        guard row < filtered.count else { return nil }
        let entry = filtered[row].1

        let cellId = NSUserInterfaceItemIdentifier("logCell")
        let cell = logTableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cell.backgroundColor = .clear
        cell.isBezeled = false
        cell.isEditable = false
        cell.isSelectable = true
        cell.maximumNumberOfLines = 0
        cell.cell?.wraps = true
        cell.cell?.isScrollable = false

        let color = logColor(for: entry.type)
        let arrow = entry.isExpanded ? "\u{25BE}" : "\u{25B8}"  // ▾ or ▸

        var text = "\(arrow) [\(entry.timestamp)] \(entry.message)"
        if entry.isExpanded {
            if let raw = entry.rawBytes {
                let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
                text += "\n  HEX: \(hex)"
            }
            if let decoded = entry.decoded {
                text += "\n  \(decoded)"
            }
        }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ])
        cell.attributedStringValue = attributed
        return cell
    }

    private func logColor(for type: LogEntryType) -> NSColor {
        switch type {
        case .tx: return NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        case .rx: return NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
        case .error: return NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
        case .buttonEvent: return NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
        case .warning: return NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)
        case .info: return NSColor(calibratedWhite: 0.75, alpha: 1.0)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): table view delegates for features, controls, and log"
```

---

### Task 7: Data Refresh + Observers + State Machine

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (replace refresh and observer stubs)

- [ ] **Step 1: Implement full refreshAll and panel refresh methods**

Replace the `refreshAll`, `refreshRightPanels`, `refreshRightPanelsLoading` stubs:

```swift
    // MARK: - Refresh

    private func refreshAll() {
        refreshSidebar()
        refreshDeviceInfo()
        refreshFeatureTable()
        refreshControls()
        updateContextActions()
        logTableView?.reloadData()
    }

    private func refreshRightPanels() {
        refreshDeviceInfo()
        refreshFeatureTable()
        refreshControls()
        updateContextActions()
    }

    private func refreshRightPanelsLoading() {
        featureRows.removeAll()
        controlRows.removeAll()
        featureTableView?.reloadData()
        controlsTableView?.reloadData()
        // Update headers to show loading
        if let header = featureTableView?.superview?.superview?.subviews.first(where: { ($0 as? NSTextField)?.tag == 100 }) as? NSTextField {
            header.stringValue = "FEATURES (...)"
        }
        if let header = controlsTableView?.superview?.superview?.subviews.first(where: { ($0 as? NSTextField)?.tag == 101 }) as? NSTextField {
            header.stringValue = "CONTROLS (...)"
        }
        updateContextActions()
    }

    private func refreshFeatureTable() {
        guard let session = currentSession else {
            featureRows.removeAll()
            featureTableView?.reloadData()
            return
        }
        let features = session.debugFeatureIndex
        featureRows = features.sorted(by: { $0.value < $1.value }).map { (featureId, index) in
            let name = HIDPPInfo.featureNames[featureId]?.0 ?? "Unknown"
            return (
                index: String(format: "0x%02X", index),
                featureId: featureId,
                featureIdHex: String(format: "0x%04X", featureId),
                name: name
            )
        }
        featureTableView?.reloadData()

        // Update header
        updateSectionHeader(tag: 100, text: "FEATURES (\(featureRows.count))")
    }

    private func refreshControls() {
        guard let session = currentSession else {
            controlRows.removeAll()
            controlsTableView?.reloadData()
            return
        }
        controlRows = session.debugDiscoveredControls
        controlsTableView?.reloadData()

        // Update header
        updateSectionHeader(tag: 101, text: "CONTROLS (\(controlRows.count))")
    }

    private func updateSectionHeader(tag: Int, text: String) {
        // Find label by tag in the view hierarchy
        func findLabel(in view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField, tf.tag == tag { return tf }
            for sub in view.subviews {
                if let found = findLabel(in: sub) { return found }
            }
            return nil
        }
        if let contentView = window?.contentView, let label = findLabel(in: contentView) {
            label.stringValue = text
        }
    }
```

- [ ] **Step 2: Implement observers**

Replace the `startObserving` and `stopObserving` stubs:

```swift
    // MARK: - Observers

    private func startObserving() {
        stopObserving()

        logObserver = NotificationCenter.default.addObserver(
            forName: LogitechHIDDebugPanel.logNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.logTableView?.reloadData()

            // Auto-scroll to bottom
            let rowCount = self.filteredLogEntries().count
            if rowCount > 0 {
                self.logTableView?.scrollRowToVisible(rowCount - 1)
            }

            // Auto-refresh controls on button events
            if let entry = notification.object as? LogEntry,
               entry.type == .buttonEvent || entry.message.contains("divert") {
                self.refreshControls()
            }
        }

        sessionObserver = NotificationCenter.default.addObserver(
            forName: LogitechHIDManager.sessionChangedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshAll()
        }
    }

    private func stopObserving() {
        if let obs = logObserver {
            NotificationCenter.default.removeObserver(obs)
            logObserver = nil
        }
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
    }
```

- [ ] **Step 3: Verify build**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): data refresh, observers, and state machine"
```

---

### Task 8: Update Existing Log Call Sites for rawBytes Parameter

**Files:**
- Modify: `Mos/LogitechHID/LogitechDeviceSession.swift` (update log calls to pass rawBytes where available)

- [ ] **Step 1: Check if existing call sites still compile with new LogEntry**

The new `LogEntry` adds `rawBytes: [UInt8]? = nil` with a default value, and the new `log(device:type:message:decoded:rawBytes:)` method has `rawBytes` defaulting to `nil`. Existing callers that don't pass `rawBytes` should still compile.

However, the existing `LogitechDeviceSession` calls `LogitechHIDDebugPanel.log(device:type:message:decoded:)` — this signature must still exist on the new class. Verify this is the case (it is, in our Task 2 implementation).

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -20`

If there are compile errors related to `LogEntry` missing initializer parameters, fix by adding default `rawBytes: nil` to struct init. The `LogEntry` struct uses memberwise init, so the default `rawBytes: [UInt8]? = nil` declaration should provide the default.

- [ ] **Step 2: Commit if changes were needed**

```bash
git add -A
git commit -m "fix(hidpp-debug): ensure backward compatibility with existing log call sites"
```

---

### Task 9: Final Integration — Full Build + Smoke Test

**Files:**
- Modify: `Mos/LogitechHID/LogitechHIDDebugPanel.swift` (final fixes)

- [ ] **Step 1: Full clean build**

Run: `xcodebuild clean build -scheme Debug -destination 'platform=macOS' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

If there are errors, fix them iteratively. Common issues to watch for:
- Missing `@objc` on selectors
- Type mismatches between DeviceNode and outline view items
- Missing conformance declarations
- LogEntry memberwise init issues

- [ ] **Step 2: Fix any compile errors found**

Address each error one by one. The most likely issues:
- `DeviceNode` needs to be a class (not struct) for `NSOutlineView` identity
- `(session:slot:)` tuple type issues — may need a wrapper class
- `LogitechCIDRegistry.name(for:)` method name may differ from actual API

- [ ] **Step 3: Verify no warnings**

Run: `xcodebuild build -scheme Debug -destination 'platform=macOS' 2>&1 | grep -i "warning:" | head -10`

Fix any warnings related to the new code.

- [ ] **Step 4: Final commit**

```bash
git add Mos/LogitechHID/LogitechHIDDebugPanel.swift
git commit -m "feat(hidpp-debug): complete redesign with IDE-style layout and frosted glass theme"
```

- [ ] **Step 5: Push to remote**

```bash
git push origin master
```
