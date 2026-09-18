//
//  ScrollFilterTests.swift
//  MosTests
//
//  ScrollFilter 曲线滤波测试 (Task 6)
//

import XCTest
@testable import Mos_Debug

final class ScrollFilterTests: XCTestCase {

    var sut: ScrollFilter!

    override func setUp() {
        super.setUp()
        sut = ScrollFilter()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - 初始状态

    func testInitialValue_isZero() {
        let val = sut.value()
        XCTAssertEqual(val.y, 0.0, accuracy: 1e-10)
        XCTAssertEqual(val.x, 0.0, accuracy: 1e-10)
    }

    func testInitialCurveWindows_areZeroArrays() {
        XCTAssertEqual(sut.curveWindowY, [0.0, 0.0])
        XCTAssertEqual(sut.curveWindowX, [0.0, 0.0])
    }

    // MARK: - reset

    func testReset_clearsToZero() {
        _ = sut.fill(with: (y: 10.0, x: 5.0))
        sut.reset()
        let val = sut.value()
        XCTAssertEqual(val.y, 0.0, accuracy: 1e-10)
        XCTAssertEqual(val.x, 0.0, accuracy: 1e-10)
        XCTAssertEqual(sut.curveWindowY, [0.0, 0.0])
        XCTAssertEqual(sut.curveWindowX, [0.0, 0.0])
    }

    // MARK: - fill: 首次填充

    func testFill_firstCall_smoothsFromZero() {
        // 初始 curveWindowY = [0.0, 0.0]
        // polish([0, 0], with: 10) -> first=0, diff=10
        // result = [0, 0+0.23*10, 0+0.5*10, 0+0.77*10, 10] = [0, 2.3, 5, 7.7, 10]
        // value = result[0] = 0
        let result = sut.fill(with: (y: 10.0, x: 0.0))
        XCTAssertEqual(result.y, 0.0, accuracy: 1e-10, "first fill Y should return array[0] which is the old first")
        XCTAssertEqual(result.x, 0.0, accuracy: 1e-10)
    }

    // MARK: - fill: 连续填充产生平滑效果

    func testFill_secondCall_advancesToNextSmoothedValue() {
        // 第一次: curveWindowY 从 [0,0] -> [0, 2.3, 5, 7.7, 10]
        _ = sut.fill(with: (y: 10.0, x: 0.0))

        // 第二次: polish 使用 array[1]=2.3 作为 first
        // polish([0, 2.3, 5, 7.7, 10], with: 10) -> first=2.3, diff=10-2.3=7.7
        // result = [2.3, 2.3+0.23*7.7, 2.3+0.5*7.7, 2.3+0.77*7.7, 10]
        let result2 = sut.fill(with: (y: 10.0, x: 0.0))
        XCTAssertEqual(result2.y, 2.3, accuracy: 1e-10, "second fill should return smoothed value from previous polish")
    }

    func testFill_convergesToTarget_afterMultipleCalls() {
        // 反复填充相同值, 应该逐渐逼近目标
        let target = 10.0
        var lastY = 0.0
        for _ in 0..<20 {
            let result = sut.fill(with: (y: target, x: 0.0))
            XCTAssertGreaterThanOrEqual(result.y, lastY, "value should be monotonically non-decreasing toward target")
            lastY = result.y
        }
        // 经过足够多次迭代后应该接近目标
        XCTAssertEqual(lastY, target, accuracy: 0.1, "after many fills, should converge close to target")
    }

    // MARK: - fill: X 轴独立

    func testFill_xAxisIndependent() {
        _ = sut.fill(with: (y: 0.0, x: 20.0))
        let val = sut.value()
        XCTAssertEqual(val.y, 0.0, accuracy: 1e-10)
        XCTAssertEqual(val.x, 0.0, accuracy: 1e-10, "first fill x should also be smoothed from zero")

        _ = sut.fill(with: (y: 0.0, x: 20.0))
        let val2 = sut.value()
        XCTAssertEqual(val2.y, 0.0, accuracy: 1e-10, "Y axis should remain at zero")
        XCTAssertGreaterThan(val2.x, 0.0, "X axis should start advancing")
    }

    // MARK: - fill: 负值

    func testFill_negativeValues() {
        _ = sut.fill(with: (y: -10.0, x: -5.0))
        _ = sut.fill(with: (y: -10.0, x: -5.0))
        let val = sut.value()
        XCTAssertLessThan(val.y, 0.0, "negative fill should produce negative smoothed values")
        XCTAssertLessThan(val.x, 0.0, "negative fill should produce negative smoothed values")
    }

    // MARK: - fill: 方向突变

    func testFill_directionChange_smoothsTransition() {
        // 先正向填充几次
        for _ in 0..<5 {
            _ = sut.fill(with: (y: 10.0, x: 0.0))
        }
        let beforeChange = sut.value().y

        // 然后反向填充
        // polish 的 value() 返回 curveWindow[0], 即上一轮 curveWindow[1]
        // 因此第一次反向 fill 的返回值仍然反映前一轮的惯性 (会继续上升)
        _ = sut.fill(with: (y: -10.0, x: 0.0))
        let oneStepAfter = sut.value().y

        // 再填充一次反向值, 此时 curveWindow[0] 才会开始体现反向趋势
        _ = sut.fill(with: (y: -10.0, x: 0.0))
        let twoStepsAfter = sut.value().y

        // 由于平滑, 方向变化不会立即完全反转
        XCTAssertGreaterThan(beforeChange, 0.0)
        // 第二次反向 fill 后, 值应该比第一次反向 fill 后更小 (开始向负方向移动)
        XCTAssertLessThan(twoStepsAfter, oneStepAfter, "direction change should start moving value toward new target after smoothing delay")
    }

    // MARK: - polish 机制验证

    func testPolish_generatesCorrectIntermediateValues() {
        // 直接验证 curveWindow 的中间值
        _ = sut.fill(with: (y: 10.0, x: 0.0))

        // curveWindowY 应该是 [0, 2.3, 5, 7.7, 10]
        XCTAssertEqual(sut.curveWindowY.count, 5)
        XCTAssertEqual(sut.curveWindowY[0], 0.0, accuracy: 1e-10)
        XCTAssertEqual(sut.curveWindowY[1], 2.3, accuracy: 1e-10)
        XCTAssertEqual(sut.curveWindowY[2], 5.0, accuracy: 1e-10)
        XCTAssertEqual(sut.curveWindowY[3], 7.7, accuracy: 1e-10)
        XCTAssertEqual(sut.curveWindowY[4], 10.0, accuracy: 1e-10)
    }

    // MARK: - value 与 fill 返回值一致

    func testFill_returnValue_matchesValue() {
        let fillResult = sut.fill(with: (y: 7.0, x: 3.0))
        let valueResult = sut.value()
        XCTAssertEqual(fillResult.y, valueResult.y, accuracy: 1e-10)
        XCTAssertEqual(fillResult.x, valueResult.x, accuracy: 1e-10)
    }
}
