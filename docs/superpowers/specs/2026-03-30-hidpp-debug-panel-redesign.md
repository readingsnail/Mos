# HID++ Debug Panel Redesign

## Overview

Redesign the Logitech HID++ Debug Panel from its current 5-section vertical layout into a modern IDE-style interface with NSVisualEffectView frosted glass dark theme, matching the Toast Debug Panel's visual language.

## Goals

1. Modernize visual design with `.hudWindow` + `.vibrantDark` frosted glass style
2. Reorganize layout for efficient debugging workflow: device selection → state inspection → action execution → log monitoring
3. Support known HID++ features as selectable test actions, plus generic function call for unknown features
4. Add custom raw packet sending and log export
5. Protocol log with type filtering and expandable entries
6. Left sidebar device navigator with tree view and hot-plug dynamic updates

## Window Configuration

Follows `ToastPanel.swift` construction pattern exactly:

- **Window type**: `NSPanel` (not `NSWindow`)
- **Style mask**: `.titled`, `.closable`, `.miniaturizable`, `.resizable`, `.fullSizeContentView`
- **Default size**: 1100x750, **minimum**: 1100x600, resizable
- **Title**: `"Logitech HID++ Debug"`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`
- **Background**: `NSVisualEffectView` as root `contentView`
  - material: `.hudWindow` (macOS 10.14+) / `.dark` (10.13 fallback)
  - blendingMode: `.behindWindow`
  - state: `.active`
- **Appearance**: set on panel itself — `panel.appearance = NSAppearance(named: .vibrantDark)` (available since macOS 10.10, no version guard needed)
- **Top inset**: derived from `contentLayoutRect` like ToastPanel's `resolvedTopInset()`
- **Shadow**: `hasShadow = true`
- **Behavior**: `isMovableByWindowBackground = true`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`
- **Layout**: 100% programmatic, frame-based with `autoresizingMask` for resize support

## Layout Structure

```
+-------------------------------------------------------------------+
|  [Close][Min]              (transparent titlebar)                  |
+----------+--------------------------------------------------------+
|          |  FEATURES (5)    | CONTROLS (7)   | ACTIONS            |
| DEVICES  |  +-----------+   | +-----------+   | [Context Actions]  |
|          |  | 0x00 IRoot|   | | Left  .   |   | based on selection |
| [M] MX   |  | 0x01 IFeat|   | | Right .   |   |                    |
|   Master |  | 0x04 Repro|   | | Mid DVRT  |   | --- Global ---     |
|   . BLE  |  | 0x05 Smart|   | | Back DVRT |   | [Re-Discover]      |
|          |  | 0x06 DPI  |   | | Fwd  .    |   | [Re-Divert]        |
| [R] Bolt |  +-----------+   | +-----------+   | [Undivert All]     |
|  |- Slot1|                  |                  | [Enumerate]        |
|  +- Slot2|                  |                  | [Clear Log]        |
+----------+------------------------------------------------------ +
| Device   |  PROTOCOL LOG                              [Filters]    |
| Info     |  > TX IRoot.GetFeature(0x1B04)          >  [Export]     |
| VID 046D |  < RX idx=0x04 ok                       >  [Clear]     |
| PID B034 |  ! Button: Back (0x53) DOWN                             |
| Proto 4.2|  x ERR: InvalidFeatureIdx               >              |
| BLE      |  ------------------------------------------------      |
| Idx 0xFF |  RAW: [11 FF 00 01 1B 04 00 ...        ] [Send]        |
| [More..] |                                                         |
+----------+--------------------------------------------------------+
```

## Section 1: Left Sidebar — Device Navigator (180px fixed)

### Upper Area — Device Tree (flexible height)

- Section label: `"DEVICES"` (10pt medium, tertiaryLabelColor)
- Implementation: `NSOutlineView` with tree data source
- **BLE Direct devices**: single-level nodes
  - Text prefix `[M]` (mouse) or `[K]` (keyboard) + device name + status dot
  - Green dot = connected, no red/offline nodes (disconnected devices are removed from tree)
  - **Unsupported Logitech interfaces** (connectionMode == .unsupported) are filtered out and do not appear in the sidebar
- **Receiver devices**: expandable parent nodes
  - Parent: `[R]` prefix + receiver name + connection status
  - Children: Slot 1-6, showing `device name (type)` or `empty`, online/offline per receiver enumeration
  - Current target slot highlighted with blue selection background
- **Hot-plug**: observe `LogitechHIDManager` session add/remove notifications, auto-refresh outline view
  - Only connected sessions appear (no offline caching — matches `LogitechHIDManager.activeSessions` behavior)
  - When a device disconnects, its node is removed; if it was selected, select the first remaining device or show empty state
- Click device/slot → trigger slot-switch flow (see State Machine section)
- **Icons**: use text-based prefixes `[M]`/`[R]`/`[K]`, not emoji, for rendering consistency across macOS versions

### Lower Area — Device Info (fixed ~140px)

- 1px separator line above
- **Primary info** (always visible):
  - VID / PID (hex format)
  - Protocol version
  - Transport (BLE / USB)
  - Device Index
  - Connection Mode
  - Opened status (checkmark / cross mark)
- **Expandable "More" section** (click to toggle):
  - Usage Page / Usage
  - HID++ Candidate status
  - Init Complete status
  - Diverted CIDs count
  - Feature cache status
- 9pt monospace font, compact two-column layout (key left-aligned, value right-aligned)

## Section 2: Upper Right — Three-Column Info Area (~40% height)

### Left Column — Features Table (flex: 1)

- Header: `"FEATURES (N)"` with count
- `NSTableView` single-select, 3 columns: Index (hex), Feature ID (hex), Name
- Click row → Actions column updates to show available functions for that feature
- Empty state: gray placeholder `"No features discovered"`
- Loading state: gray placeholder `"Discovering features..."` with activity indicator
- Right-click context menu: `Copy Feature ID`

### Middle Column — Controls Table (flex: 1)

- Header: `"CONTROLS (N)"` with count
- `NSTableView`, 4 columns: CID (hex), Name, Flags (iconized), Status
- Status indicators:
  - Green dot = normal
  - Orange `DVRT` badge = diverted
  - Yellow `REMAP` badge = remapped
- Click row → Actions column updates to show control-specific operations
- Empty state: gray placeholder `"No controls discovered"`
- Loading state: gray placeholder `"Discovering controls..."`

### Right Column — Actions Panel (160px fixed)

#### Upper Section — Context Actions (dynamic)

Based on Features/Controls table selection:

**When a Feature is selected**, show callable functions. For known features, show named functions:
- IRoot (0x0000): `Ping`, `GetFeature`
- IFeatureSet (0x0001): `GetCount`, `GetFeatureID`
- ReprogControlsV4 (0x1B04): `GetCount`, `GetInfo`, `GetReporting`, `SetReporting`
- SmartShift (0x2110): `GetStatus`, `SetStatus`
- AdjustableDPI (0x2201): `GetSensorCount`, `GetDPI`, `SetDPI`, `GetDPIList`
- HiResWheel (0x2121): `GetCapability`, `GetMode`, `SetMode`
- BatteryStatus (0x1000): `GetLevel`
- UnifiedBattery (0x1004): `GetStatus`
- DeviceFWVersion (0x0003): `GetEntityCount`, `GetFWVersion`
- DeviceNameType (0x0005): `GetCount`, `GetName`, `GetType`

**Parameter handling for named actions**:
- **Getter functions** (GetStatus, GetDPI, GetCount, GetLevel, etc.): send with all-zero parameters, no user input needed. These are read-only queries.
- **Setter functions** (SetStatus, SetDPI, SetMode, SetReporting): show a hex parameter input field below the button. The field pre-fills with common defaults where known (e.g., SetReporting pre-fills with CID bytes + divert flag). User can edit before sending.
- **Functions requiring an index** (GetFeatureID, GetControlInfo, GetName, GetFWVersion): show a small numeric index stepper (0-255) to select the entity index.

For **unknown/other features**: show generic `Func 0` through `Func 15` buttons. Each button sends a HID++ 2.0 request with the selected feature's index and the function ID. All show a hex parameter input field (default all zeros) that user can edit before sending.

**Implementation**: actions construct packets directly in the debug panel using the raw `IOHIDDeviceSetReport` path (same as raw packet sender), not via `LogitechDeviceSession`'s high-level API. This avoids needing to extend the session's public API while enabling arbitrary protocol exploration. The panel constructs the 20-byte HID++ 2.0 long report: `[0x11, deviceIndex, featureIndex, (funcId << 4) | 0x01, params...]`.

**When a Control is selected**, show:
- `Divert` / `Undivert` toggle (calls existing `session.setControlDivert()`)
- `Query Reporting` — sends GetControlReporting (func 2) via raw packet; **panel parses the RX response itself** to extract reportingFlags and targetCID, then updates the in-memory `discoveredControls` array and refreshes the Controls table. This avoids modifying session internals.
- Display current flags and target CID

**When nothing is selected**: gray text `"Select a feature or control"`

#### Lower Section — Global Actions (fixed)

Separator line, then always-visible buttons:
- `Re-Discover` — calls `session.rediscoverFeatures()` which clears in-memory feature/control state and re-runs discovery (persisted UserDefaults cache is NOT cleared — that only updates when new discovery results arrive)
- `Re-Divert` — re-apply divert bindings
- `Undivert All` — remove all diverts
- `Enumerate` — receiver enumeration (disabled for BLE devices)
- `Clear Log` — clear protocol log

Button style: 24px height, blue semi-transparent background + border, compact

## Section 3: Lower Area — Protocol Log (~60% height)

### Toolbar Row

- Left: section label `"PROTOCOL LOG"`
- Center/Right: filter toggle chips — `TX` `RX` `ERR` `BTN` `WARN` `INFO`
  - Each chip is a toggle button, active = highlighted color, inactive = dimmed
  - All active by default
- Far right: `Export` button + `Clear` button

### Log Body

- `NSTableView` (single-column, variable row height) inside `NSScrollView` — NOT `NSTextView`
  - Enables per-row expand/collapse, row selection, and structured data binding
  - Each row backed by an enhanced `LogEntry` model
- 11pt monospace font, terminal aesthetic on dark background (`rgba(0,0,0,0.4)`)
- Color coding per row (same as current):
  - TX: Blue (0.4, 0.6, 1.0)
  - RX: Green (0.3, 0.8, 0.4)
  - Error: Red (1.0, 0.3, 0.3)
  - Button Event: Yellow (1.0, 0.8, 0.2)
  - Warning: Orange (1.0, 0.6, 0.2)
  - Info: Gray (0.75)
- **Expandable entries**: each row shows summary line; click expand indicator to reveal detail view
  - Collapsed: `[arrow] [timestamp] [direction] summary` (single line)
  - Expanded: adds hex dump in grouped format (`11 FF 00 01 | 1B 04 00 00 | ...`) and decoded field annotations (`reportId=0x11, devIdx=0xFF, featureIdx=0x00, funcId=0, swId=1`)
  - Arrow indicator: `>` collapsed, `v` expanded
- Auto-scroll to bottom on new entries (disable auto-scroll if user has scrolled up manually)
- Buffer limit: 500 entries max
- **Filtering**: when a filter chip is deactivated, matching rows are hidden (not removed from buffer)

### Enhanced LogEntry Model

Extend existing `LogEntry` to support structured data:

```swift
struct LogEntry {
    let timestamp: String
    let deviceName: String
    let type: LogEntryType
    let message: String        // summary line (preserved for backward compatibility)
    let decoded: String?       // decoded annotation (preserved)
    let rawBytes: [UInt8]?     // NEW: raw packet bytes for hex dump display
    var isExpanded: Bool       // NEW: UI state for expand/collapse
}
```

### Raw Packet Input Bar

- 1px separator line
- Layout: `"RAW:"` label + hex text field + report type selector + `Send` button
- Text field: monospace, placeholder `"11 FF 00 01 1B 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00"`
- **Report type selector**: segmented control with `Short (7B)` / `Long (20B)` options
  - Short: reportID 0x10, auto-pad to 7 bytes
  - Long: reportID 0x11, auto-pad to 20 bytes
  - Default: Long
- **Input validation**:
  - Only hex characters (0-9, A-F, a-f) and spaces accepted
  - Auto-format: insert space every 2 characters on input
  - Reject if total byte count exceeds report length
  - Show inline error for invalid input (red text below field)
- **Send button**: green accent style
  - Disabled when: no device selected, device not opened, input empty/invalid
  - Sends via `IOHIDDeviceSetReport` with appropriate reportID and length
  - For receiver mode: automatically uses current target slot's deviceIndex
- Sent packet auto-logged as TX entry with raw bytes; response appears as RX entry

### Export Behavior

- `Export` button opens `NSSavePanel` with default filename `"hidpp-debug-YYYY-MM-DD-HHmmss.log"`
- Exports the **full 500-entry buffer** (not filtered view), including:
  - Timestamp, device name, type tag, message, and decoded text for each entry
  - Raw hex bytes (if available) on a second line
- Format: plain text, one entry per line (or two lines if hex dump present)

## State Machine

### Panel States

| State | Sidebar | Features | Controls | Actions | Log | Raw Sender |
|-------|---------|----------|----------|---------|-----|------------|
| **No devices** | Empty + `"No devices connected"` | Disabled, empty | Disabled, empty | All disabled | Active (can show old logs) | Disabled |
| **Device selected, not opened** | Device shown, selected | `"Device not opened"` | `"Device not opened"` | All disabled except Clear Log | Active | Disabled |
| **Device selected, unsupported** | Device shown | `"Unsupported device"` | `"Unsupported device"` | All disabled except Clear Log | Active | Disabled |
| **Discovering features** | Device shown | `"Discovering..."` + spinner | `"Discovering..."` | Global actions enabled | Active | Enabled |
| **Ready** | Device shown | Feature list | Control list | Full functionality | Active | Enabled |
| **Receiver enumerating** | Receiver shown, slots loading | Previous state | Previous state | Enumerate disabled | Active | Enabled (if was ready) |

### Slot Switch Flow

1. User clicks receiver slot in sidebar
2. Validate slot is 1-6 and online
3. Call `session.setTargetSlot(slot)` — this resets in-memory feature/control state and posts session-changed notification
4. Immediately transition Features/Controls to "Discovering..." loading state (triggered by session-changed notification)
5. **Debug panel explicitly calls `session.rediscoverFeatures()`** to kick off feature discovery for the new slot
6. Session discovers features → posts session-changed notification again → panel refreshes to Ready state
7. If discovery times out (5s): show `"Discovery timed out"` with `Retry` button

## Visual Style Details

### Typography

| Element | Size | Weight | Color |
|---------|------|--------|-------|
| Section headers | 10pt | medium | tertiaryLabelColor |
| Table content | 11pt | regular | labelColor |
| Device info values | 9pt | regular (monospace) | secondaryLabelColor |
| Log entries | 11pt | regular (monospace) | per-type color coding |
| Action buttons | 11pt | medium | labelColor |
| Filter chips | 10pt | medium | per-type color when active |

### Colors

Inherit vibrancy from `.vibrantDark` appearance. Specific colors:
- Panel backgrounds: `rgba(255,255,255,0.05)` for info sections
- Log background: `rgba(0,0,0,0.4)` for terminal contrast
- Separators: `rgba(255,255,255,0.1)`
- Active selection: `rgba(100,160,255,0.2)` background
- Action buttons: `rgba(100,160,255,0.15)` background + `rgba(100,160,255,0.3)` border
- Send button: `rgba(100,200,100,0.15)` background + `rgba(100,200,100,0.3)` border
- Status badges: DVRT = orange `rgba(255,160,0,0.8)`, REMAP = yellow `rgba(255,200,50,0.8)`

### Spacing

- Sidebar width: 180px
- Section gaps: 2px
- Internal padding: 8px
- Action button height: 24px
- Button vertical spacing: 4px
- Filter chip horizontal spacing: 4px

## Data Flow

1. `LogitechHIDManager` notifies device connect/disconnect → sidebar refreshes (add/remove nodes)
2. User clicks device in sidebar → `currentSession` updated → trigger slot-switch flow if receiver, else refresh panels
3. Feature/Control tables populated from `currentSession.featureIndex` and `currentSession.discoveredControls`
4. User clicks feature row → Actions panel queries `HIDPPInfo.featureNames` for available functions
5. User clicks action button → panel constructs HID++ packet directly → sends via `IOHIDDeviceSetReport` → logs TX with raw bytes
6. Session receives response via input report callback → logs RX with raw bytes → updates relevant tables if state changed
7. Raw packet input → validates hex + report type → sends via `IOHIDDeviceSetReport` → logs TX/RX

## Migration Notes

- Replace entire `LogitechHIDDebugPanel.swift` (791 lines) with new implementation
- Enhance `LogEntry` struct with `rawBytes` and `isExpanded` fields (backward compatible — existing callers still use `message` + `decoded`)
- Preserve all existing `LogEntryType`, notification names, and logging API signatures
- Keep `HIDPPInfo`, `LogitechCIDRegistry` as-is (read-only data)
- Do not modify `LogitechDeviceSession` or `LogitechHIDManager` public APIs
- Feature action buttons and raw sender both use `IOHIDDeviceSetReport` directly, bypassing session's high-level methods

## macOS Compatibility

- All APIs must be compatible with macOS 10.13+
- `NSVisualEffectView.material = .hudWindow` requires macOS 10.14+ (fallback to `.dark` on 10.13)
- `NSAppearance(named: .vibrantDark)` available since macOS 10.10 — no version guard needed
- Use `NSFont.monospacedDigitSystemFont` for monospace (available since 10.11)
- `NSOutlineView` available since macOS 10.0+
- `NSTableView` with variable row heights: use `usesAutomaticRowHeights = false`, manually calculate row heights
- Avoid `NSGridView` (10.12+), use manual frame layout for maximum compatibility
- `NSSavePanel` available since macOS 10.0+
