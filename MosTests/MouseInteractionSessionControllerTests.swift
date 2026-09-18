import XCTest
@testable import Mos_Debug

final class MouseInteractionSessionControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Options.shared.buttons.binding = []
        ButtonUtils.shared.invalidateCache()
        MouseInteractionSessionController.shared.setTestingMotionTapHooks()
        MouseInteractionSessionController.shared.clearAllSessions()
        InputProcessor.shared.clearActiveBindings()
    }

    override func tearDown() {
        InputProcessor.shared.clearActiveBindings()
        MouseInteractionSessionController.shared.clearAllSessions()
        MouseInteractionSessionController.shared.clearTestingMotionTapHooks()
        Options.shared.buttons.binding = []
        ButtonUtils.shared.invalidateCache()
        super.tearDown()
    }

    private func activateVirtualModifiers(_ modifiers: [(code: UInt16, shortcut: String)]) {
        Options.shared.buttons.binding = modifiers.map { modifier in
            let trigger = RecordedEvent(
                type: .mouse,
                code: modifier.code,
                modifiers: 0,
                displayComponents: ["🖱\(modifier.code + 1)"],
                deviceFilter: nil
            )
            return ButtonBinding(
                triggerEvent: trigger,
                systemShortcutName: modifier.shortcut,
                isEnabled: true
            )
        }
        ButtonUtils.shared.invalidateCache()

        for modifier in modifiers {
            let event = InputEvent(
                type: .mouse,
                code: modifier.code,
                modifiers: .init(rawValue: 0),
                phase: .down,
                source: .hidPP,
                device: nil
            )
            XCTAssertEqual(InputProcessor.shared.process(event), .consumed)
        }
    }

    func testSyntheticTargetPriority_leftBeatsRightAndOther() {
        XCTAssertEqual(
            MouseInteractionSessionController.dominantSyntheticTarget(from: [
                .other(buttonNumber: 4),
                .right,
                .left,
            ]),
            .left
        )
        XCTAssertEqual(
            MouseInteractionSessionController.dominantSyntheticTarget(from: [
                .other(buttonNumber: 4),
                .other(buttonNumber: 3),
            ]),
            .other(buttonNumber: 3)
        )
    }

    func testEffectiveTarget_prefersPhysicalLeftOverSyntheticRight() {
        XCTAssertEqual(
            MouseInteractionSessionController.effectiveTarget(
                physical: .left,
                synthetic: .right
            ),
            .left
        )
    }

    func testEffectiveTarget_upgradesMouseMovedToSyntheticLeftDragged() {
        XCTAssertEqual(
            MouseInteractionSessionController.effectiveTarget(
                physical: .none,
                synthetic: .left
            ),
            .left
        )
    }

    func testSessionLifecycle_startsOnFirstMouseSession_andStopsOnLast() {
        var startCount = 0
        var stopCount = 0
        let controller = MouseInteractionSessionController(
            startMotionTap: { startCount += 1 },
            stopMotionTap: { stopCount += 1 }
        )

        XCTAssertFalse(controller.isMotionTapRunning)

        let leftSessionID = controller.beginSession(target: .left)
        XCTAssertTrue(controller.isMotionTapRunning)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        let rightSessionID = controller.beginSession(target: .right)
        XCTAssertTrue(controller.isMotionTapRunning)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        controller.endSession(id: leftSessionID)
        XCTAssertTrue(controller.isMotionTapRunning)
        XCTAssertEqual(stopCount, 0)

        controller.endSession(id: rightSessionID)
        XCTAssertFalse(controller.isMotionTapRunning)
        XCTAssertEqual(stopCount, 1)
    }

    func testRewriteMouseInteractionEvent_withSyntheticLeftConvertsMouseMovedToLeftDragged() {
        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        _ = controller.beginSession(target: .left)

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 120, y: 60),
            mouseButton: .left
        )!

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 0)
    }

    func testRewriteMouseInteractionEvent_withSyntheticOtherSetsOtherDraggedAndButtonNumber() {
        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        _ = controller.beginSession(target: .other(buttonNumber: 4))

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 20, y: 10),
            mouseButton: .left
        )!

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .otherMouseDragged)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 4)
    }

    func testRewriteMouseInteractionEvent_prefersHigherPrioritySyntheticLeftOverPhysicalRight() {
        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        _ = controller.beginSession(target: .left)

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDragged,
            mouseCursorPosition: CGPoint(x: 55, y: 42),
            mouseButton: .right
        )!
        event.setIntegerValueField(.mouseEventButtonNumber, value: 1)

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventButtonNumber), 0)
    }

    func testRewriteMouseInteractionEvent_appliesVirtualModifierFlags() {
        activateVirtualModifiers([(code: 6, shortcut: "custom::56:0")])

        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        _ = controller.beginSession(target: .left)

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 80, y: 44),
            mouseButton: .left
        )!

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertTrue(event.flags.contains(.maskShift))
    }

    func testRewriteMouseInteractionEvent_withOnlyVirtualModifiers_preservesMouseMovedAndAppliesFlags() {
        activateVirtualModifiers([(code: 6, shortcut: "custom::58:0")])

        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 80, y: 44),
            mouseButton: .left
        )!

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertTrue(event.flags.contains(.maskAlternate))
    }

    func testRewriteMouseInteractionEvent_withOnlyVirtualModifiers_preservesPhysicalDraggedTypeAndAppliesFlags() {
        activateVirtualModifiers([(code: 6, shortcut: "custom::56:0")])

        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: 80, y: 44),
            mouseButton: .left
        )!

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertTrue(event.flags.contains(.maskShift))
    }

    func testRewriteMouseInteractionEvent_withMultipleVirtualModifiers_preservesMouseMovedAndAppliesAllFlags() {
        activateVirtualModifiers([
            (code: 6, shortcut: "custom::58:0"),
            (code: 7, shortcut: "custom::56:0"),
        ])

        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 90, y: 30),
            mouseButton: .left
        )!

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertTrue(event.flags.contains(.maskAlternate))
        XCTAssertTrue(event.flags.contains(.maskShift))
    }

    func testRewriteMouseInteractionEvent_combinesPhysicalAndVirtualModifierFlagsOnMouseMoved() {
        activateVirtualModifiers([(code: 6, shortcut: "custom::56:0")])

        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 90, y: 30),
            mouseButton: .left
        )!
        event.flags = .maskAlternate

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertTrue(event.flags.contains(.maskAlternate))
        XCTAssertTrue(event.flags.contains(.maskShift))
    }

    func testRewriteMouseInteractionEvent_withMultipleVirtualModifiers_preservesPhysicalDraggedTypeAndAppliesAllFlags() {
        activateVirtualModifiers([
            (code: 6, shortcut: "custom::58:0"),
            (code: 7, shortcut: "custom::56:0"),
        ])

        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: 100, y: 60),
            mouseButton: .left
        )!
        event.flags = .maskCommand

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertTrue(event.flags.contains(.maskAlternate))
        XCTAssertTrue(event.flags.contains(.maskShift))
        XCTAssertTrue(event.flags.contains(.maskCommand))
    }

    func testRewriteMouseInteractionEvent_withSyntheticLeftAndMultipleVirtualModifiers_convertsMouseMovedAndAppliesAllFlags() {
        activateVirtualModifiers([
            (code: 6, shortcut: "custom::58:0"),
            (code: 7, shortcut: "custom::56:0"),
        ])

        let controller = MouseInteractionSessionController(startMotionTap: {}, stopMotionTap: {})
        _ = controller.beginSession(target: .left)

        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 60, y: 22),
            mouseButton: .left
        )!

        controller.rewriteMouseInteractionEvent(event)

        XCTAssertEqual(event.type, .leftMouseDragged)
        XCTAssertTrue(event.flags.contains(.maskAlternate))
        XCTAssertTrue(event.flags.contains(.maskShift))
    }

    func testRefreshMotionTapState_followsSharedVirtualModifierStateWithoutLocalCache() {
        var startCount = 0
        var stopCount = 0
        let controller = MouseInteractionSessionController(
            startMotionTap: { startCount += 1 },
            stopMotionTap: { stopCount += 1 }
        )

        XCTAssertFalse(controller.isMotionTapRunning)

        activateVirtualModifiers([(code: 6, shortcut: "custom::58:0")])
        controller.refreshMotionTapState()
        XCTAssertTrue(controller.isMotionTapRunning)
        XCTAssertEqual(startCount, 1)

        InputProcessor.shared.clearActiveBindings()
        controller.refreshMotionTapState()
        XCTAssertFalse(controller.isMotionTapRunning)
        XCTAssertEqual(stopCount, 1)
    }
}
