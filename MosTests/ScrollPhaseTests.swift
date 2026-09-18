//
//  ScrollPhaseTests.swift
//  MosTests
//
//  ScrollPhase 状态机完整转换测试 (Task 5)
//

import XCTest
@testable import Mos_Debug

final class ScrollPhaseTests: XCTestCase {

    var sut: ScrollPhase!

    override func setUp() {
        super.setUp()
        sut = ScrollPhase()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - 初始状态

    func testInitialPhaseIsIdle() {
        XCTAssertEqual(sut.phase, .Idle)
    }

    // MARK: - reset

    func testResetBringsBackToIdle() {
        // 先推进到非 Idle 状态
        // isSeparated=true 从 Idle 返回 queue (非 target), 需要应用 queue 中的条目
        let plan = sut.onManualInputDetected(isSeparated: true)
        for entry in plan.queue {
            sut.apply(phase: entry.0, autoAdvance: entry.1)
        }
        if let target = plan.target {
            sut.apply(phase: target.0, autoAdvance: target.1)
        }
        XCTAssertNotEqual(sut.phase, .Idle)
        sut.reset()
        XCTAssertEqual(sut.phase, .Idle)
    }

    // MARK: - onManualInputDetected: 首次输入 (Idle -> TrackingBegin)

    func testFirstSeparatedInput_emitsTrackingBeginInQueue() {
        let plan = sut.onManualInputDetected(isSeparated: true)
        // isSeparated=true 时, queue 包含 TrackingBegin (作为额外帧)
        XCTAssertFalse(plan.queue.isEmpty, "separated input from Idle should produce queue with TrackingBegin")
        XCTAssertEqual(plan.queue.first?.0, .TrackingBegin)
        XCTAssertEqual(plan.queue.first?.1, .TrackingOngoing)
    }

    func testFirstNonSeparatedInput_targetIsTrackingBegin() {
        let plan = sut.onManualInputDetected(isSeparated: false)
        // isSeparated=false, 从 Idle -> TrackingBegin
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingBegin)
        XCTAssertEqual(plan.target?.1, .TrackingOngoing)
    }

    // MARK: - onManualInputDetected: 连续输入 (TrackingOngoing)

    func testContinuousInput_staysTrackingOngoing() {
        // 推进到 TrackingOngoing
        sut.apply(phase: .TrackingBegin, autoAdvance: .TrackingOngoing)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .TrackingOngoing)

        let plan = sut.onManualInputDetected(isSeparated: false)
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingOngoing)
    }

    // MARK: - onManualInputDetected: 惯性中断 (MomentumOngoing -> 补发 MomentumEnd + TrackingBegin)

    func testInterruptMomentum_separated_emitsExtraFrames() {
        sut.apply(phase: .MomentumOngoing)
        let plan = sut.onManualInputDetected(isSeparated: true)
        // 应该补发 MomentumEnd + TrackingBegin
        XCTAssertEqual(plan.queue.count, 2, "interrupting momentum with separated should produce 2 extra frames")
        XCTAssertEqual(plan.queue[0].0, .MomentumEnd)
        XCTAssertEqual(plan.queue[1].0, .TrackingBegin)
    }

    func testInterruptMomentum_notSeparated_emitsExtraMomentumEnd() {
        sut.apply(phase: .MomentumOngoing)
        let plan = sut.onManualInputDetected(isSeparated: false)
        // 补发 MomentumEnd, target 为 TrackingBegin
        XCTAssertEqual(plan.queue.count, 1)
        XCTAssertEqual(plan.queue[0].0, .MomentumEnd)
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingBegin)
    }

    // MARK: - onManualInputEnded

    func testManualInputEnded_fromTracking_producesTrackingEnd() {
        sut.apply(phase: .TrackingOngoing)
        let plan = sut.onManualInputEnded()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingEnd)
    }

    func testManualInputEnded_fromIdle_producesNoPlan() {
        XCTAssertEqual(sut.phase, .Idle)
        let plan = sut.onManualInputEnded()
        XCTAssertNil(plan.target)
        XCTAssertTrue(plan.queue.isEmpty)
    }

    func testManualInputEnded_fromTrackingBegin_producesTrackingEnd() {
        sut.apply(phase: .TrackingBegin)
        let plan = sut.onManualInputEnded()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingEnd)
    }

    // MARK: - onMomentumStart

    func testMomentumStart_fromTrackingEnd() {
        sut.apply(phase: .TrackingEnd)
        let plan = sut.onMomentumStart()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .MomentumBegin)
        XCTAssertEqual(plan.target?.1, .MomentumOngoing)
    }

    func testMomentumStart_fromMomentumEnd() {
        sut.apply(phase: .MomentumEnd)
        let plan = sut.onMomentumStart()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .MomentumBegin)
    }

    func testMomentumStart_fromMomentumBegin_advancesToOngoing() {
        sut.apply(phase: .MomentumBegin)
        let plan = sut.onMomentumStart()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .MomentumOngoing)
    }

    func testMomentumStart_fromIdle_producesNoPlan() {
        let plan = sut.onMomentumStart()
        XCTAssertNil(plan.target)
        XCTAssertTrue(plan.queue.isEmpty)
    }

    // MARK: - onMomentumOngoing

    func testMomentumOngoing_fromMomentumBegin() {
        sut.apply(phase: .MomentumBegin)
        let plan = sut.onMomentumOngoing()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .MomentumOngoing)
    }

    func testMomentumOngoing_fromOtherPhase_noPlan() {
        sut.apply(phase: .TrackingOngoing)
        let plan = sut.onMomentumOngoing()
        XCTAssertNil(plan.target)
    }

    // MARK: - onMomentumFinish

    func testMomentumFinish_fromMomentumOngoing() {
        sut.apply(phase: .MomentumOngoing)
        let plan = sut.onMomentumFinish()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .MomentumEnd)
        XCTAssertEqual(plan.target?.1, .Idle)
    }

    func testMomentumFinish_fromMomentumBegin() {
        sut.apply(phase: .MomentumBegin)
        let plan = sut.onMomentumFinish()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .MomentumEnd)
        XCTAssertEqual(plan.target?.1, .Idle)
    }

    func testMomentumFinish_fromTracking_producesTrackingEnd() {
        sut.apply(phase: .TrackingOngoing)
        let plan = sut.onMomentumFinish()
        XCTAssertNotNil(plan.target)
        XCTAssertEqual(plan.target?.0, .TrackingEnd)
        XCTAssertEqual(plan.target?.1, .Idle)
    }

    func testMomentumFinish_fromIdle_noPlan() {
        let plan = sut.onMomentumFinish()
        XCTAssertNil(plan.target)
        XCTAssertTrue(plan.queue.isEmpty)
    }

    // MARK: - didDeliverFrame (autoAdvance)

    func testDidDeliverFrame_appliesAutoAdvance() {
        sut.apply(phase: .TrackingBegin, autoAdvance: .TrackingOngoing)
        XCTAssertEqual(sut.phase, .TrackingBegin)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .TrackingOngoing)
    }

    func testDidDeliverFrame_withoutAutoAdvance_noChange() {
        sut.apply(phase: .TrackingOngoing, autoAdvance: nil)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .TrackingOngoing)
    }

    func testDidDeliverFrame_clearsAutoAdvance() {
        sut.apply(phase: .MomentumBegin, autoAdvance: .MomentumOngoing)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .MomentumOngoing)
        // 第二次调用不应该再切换
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .MomentumOngoing)
    }

    // MARK: - PhaseValueMapping

    func testPhaseValueMapping_idle() {
        let values = PhaseValueMapping[.Idle]
        XCTAssertNotNil(values)
        XCTAssertEqual(values?[.Scroll], 0.0)
        XCTAssertEqual(values?[.Momentum], 0.0)
    }

    func testPhaseValueMapping_trackingBegin() {
        let values = PhaseValueMapping[.TrackingBegin]
        XCTAssertNotNil(values)
        XCTAssertEqual(values?[.Scroll], 1.0)
        XCTAssertEqual(values?[.Momentum], 0.0)
    }

    func testPhaseValueMapping_momentumOngoing() {
        let values = PhaseValueMapping[.MomentumOngoing]
        XCTAssertNotNil(values)
        XCTAssertEqual(values?[.Scroll], 0.0)
        XCTAssertEqual(values?[.Momentum], 2.0)
    }

    func testPhaseValueMapping_hold() {
        let values = PhaseValueMapping[.Hold]
        XCTAssertNotNil(values)
        XCTAssertEqual(values?[.Scroll], 128.0)
        XCTAssertEqual(values?[.Momentum], 0.0)
    }

    func testPhaseValueMapping_leave() {
        let values = PhaseValueMapping[.Leave]
        XCTAssertNotNil(values)
        XCTAssertEqual(values?[.Scroll], 8.0)
        XCTAssertEqual(values?[.Momentum], 0.0)
    }

    func testPhaseValueMapping_allPhasesHaveEntries() {
        let allPhases: [Phase] = [.Idle, .Hold, .TrackingBegin, .TrackingOngoing, .TrackingEnd,
                                   .MomentumBegin, .MomentumOngoing, .MomentumEnd, .Leave]
        for phase in allPhases {
            XCTAssertNotNil(PhaseValueMapping[phase], "Missing mapping for \(phase)")
        }
    }

    // MARK: - 完整流程测试: 非惯性滚动

    func testFullFlow_nonInertialScroll() {
        // 首次输入 (separated) -> TrackingBegin
        let plan1 = sut.onManualInputDetected(isSeparated: true)
        XCTAssertFalse(plan1.queue.isEmpty)
        // 应用 queue 中的 TrackingBegin
        sut.apply(phase: plan1.queue[0].0, autoAdvance: plan1.queue[0].1)
        XCTAssertEqual(sut.phase, .TrackingBegin)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .TrackingOngoing)

        // 连续输入
        let plan2 = sut.onManualInputDetected(isSeparated: false)
        if let target = plan2.target {
            sut.apply(phase: target.0, autoAdvance: target.1)
        }
        XCTAssertEqual(sut.phase, .TrackingOngoing)

        // 输入结束
        let plan3 = sut.onManualInputEnded()
        if let target = plan3.target {
            sut.apply(phase: target.0, autoAdvance: target.1)
        }
        XCTAssertEqual(sut.phase, .TrackingEnd)
    }

    // MARK: - 完整流程测试: 惯性滚动

    func testFullFlow_inertialScroll() {
        // TrackingBegin -> TrackingOngoing -> TrackingEnd
        sut.apply(phase: .TrackingBegin, autoAdvance: .TrackingOngoing)
        sut.didDeliverFrame()
        let planEnd = sut.onManualInputEnded()
        if let target = planEnd.target {
            sut.apply(phase: target.0, autoAdvance: target.1)
        }
        XCTAssertEqual(sut.phase, .TrackingEnd)

        // MomentumBegin
        let planMB = sut.onMomentumStart()
        if let target = planMB.target {
            sut.apply(phase: target.0, autoAdvance: target.1)
        }
        XCTAssertEqual(sut.phase, .MomentumBegin)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .MomentumOngoing)

        // MomentumFinish
        let planMF = sut.onMomentumFinish()
        if let target = planMF.target {
            sut.apply(phase: target.0, autoAdvance: target.1)
        }
        XCTAssertEqual(sut.phase, .MomentumEnd)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .Idle)
    }

    // MARK: - 完整流程测试: 惯性中断

    func testFullFlow_momentumInterrupt() {
        // 进入 MomentumOngoing
        sut.apply(phase: .MomentumOngoing)
        XCTAssertEqual(sut.phase, .MomentumOngoing)

        // 新的 separated 输入中断
        let plan = sut.onManualInputDetected(isSeparated: true)
        // 应该有 2 个 queue 条目: MomentumEnd + TrackingBegin
        XCTAssertEqual(plan.queue.count, 2)

        // 应用 MomentumEnd
        sut.apply(phase: plan.queue[0].0, autoAdvance: plan.queue[0].1)
        XCTAssertEqual(sut.phase, .MomentumEnd)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .Idle)

        // 应用 TrackingBegin
        sut.apply(phase: plan.queue[1].0, autoAdvance: plan.queue[1].1)
        XCTAssertEqual(sut.phase, .TrackingBegin)
        sut.didDeliverFrame()
        XCTAssertEqual(sut.phase, .TrackingOngoing)
    }
}
