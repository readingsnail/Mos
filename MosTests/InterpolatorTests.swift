//
//  InterpolatorTests.swift
//  MosTests
//
//  Interpolator 插值数学测试 (Task 6)
//

import XCTest
@testable import Mos_Debug

final class InterpolatorTests: XCTestCase {

    // MARK: - lerp (线性插值)

    func testLerp_zeroTransition_returnsZero() {
        let result = Interpolator.lerp(src: 5.0, dest: 10.0, trans: 0.0)
        XCTAssertEqual(result, 0.0, accuracy: 1e-10)
    }

    func testLerp_fullTransition_returnsDiff() {
        let result = Interpolator.lerp(src: 0.0, dest: 10.0, trans: 1.0)
        XCTAssertEqual(result, 10.0, accuracy: 1e-10)
    }

    func testLerp_halfTransition() {
        let result = Interpolator.lerp(src: 0.0, dest: 10.0, trans: 0.5)
        XCTAssertEqual(result, 5.0, accuracy: 1e-10)
    }

    func testLerp_negativeDiff() {
        let result = Interpolator.lerp(src: 10.0, dest: 0.0, trans: 0.5)
        XCTAssertEqual(result, -5.0, accuracy: 1e-10)
    }

    func testLerp_srcEqualsDest() {
        let result = Interpolator.lerp(src: 5.0, dest: 5.0, trans: 0.5)
        XCTAssertEqual(result, 0.0, accuracy: 1e-10)
    }

    func testLerp_formula_isDeltaTimesTrans() {
        // lerp = (dest - src) * trans
        let src = 3.0
        let dest = 17.0
        let trans = 0.3
        let expected = (dest - src) * trans
        let result = Interpolator.lerp(src: src, dest: dest, trans: trans)
        XCTAssertEqual(result, expected, accuracy: 1e-10)
    }

    // MARK: - smoothStep2 (二阶平滑)

    func testSmoothStep2_srcEqualsDest_returnsZero() {
        // x = (dest - src) / dest = 0 -> f(0) = 0
        // 当 src == dest 时, x = 0, result = 0
        let result = Interpolator.smoothStep2(src: 10.0, dest: 10.0)
        XCTAssertEqual(result, 0.0, accuracy: 1e-10)
    }

    func testSmoothStep2_srcIsZero_returnsOne() {
        // x = (dest - 0) / dest = 1 -> f(1) = 1*1*(3-2*1) = 1
        let result = Interpolator.smoothStep2(src: 0.0, dest: 10.0)
        XCTAssertEqual(result, 1.0, accuracy: 1e-10)
    }

    func testSmoothStep2_midpoint() {
        // x = (10 - 5) / 10 = 0.5
        // f(0.5) = 0.5 * 0.5 * (3 - 2*0.5) = 0.25 * 2 = 0.5
        let result = Interpolator.smoothStep2(src: 5.0, dest: 10.0)
        XCTAssertEqual(result, 0.5, accuracy: 1e-10)
    }

    func testSmoothStep2_monotonicallyIncreasing() {
        let dest = 100.0
        var prevResult = -1.0
        // src 从 dest 到 0 (x 从 0 到 1)
        for i in stride(from: 100.0, through: 0.0, by: -5.0) {
            let result = Interpolator.smoothStep2(src: i, dest: dest)
            XCTAssertGreaterThanOrEqual(result, prevResult,
                "smoothStep2 should be monotonically increasing as src decreases, at src=\(i)")
            prevResult = result
        }
    }

    func testSmoothStep2_formula_correctness() {
        let src = 3.0
        let dest = 10.0
        let x = (dest - src) / dest
        let expected = x * x * (3 - 2 * x)
        let result = Interpolator.smoothStep2(src: src, dest: dest)
        XCTAssertEqual(result, expected, accuracy: 1e-10)
    }

    // MARK: - smoothStep3 (三阶平滑)

    func testSmoothStep3_srcEqualsDest_returnsZero() {
        let result = Interpolator.smoothStep3(src: 10.0, dest: 10.0)
        XCTAssertEqual(result, 0.0, accuracy: 1e-10)
    }

    func testSmoothStep3_srcIsZero_returnsOne() {
        // x = 1 -> f(1) = 1*1*1*(1*(1*6-15)+10) = 1*(6-15+10) = 1
        let result = Interpolator.smoothStep3(src: 0.0, dest: 10.0)
        XCTAssertEqual(result, 1.0, accuracy: 1e-10)
    }

    func testSmoothStep3_midpoint() {
        // x = 0.5
        // f(0.5) = 0.125 * (0.5 * (0.5*6 - 15) + 10) = 0.125 * (0.5 * (-12) + 10) = 0.125 * 4 = 0.5
        let result = Interpolator.smoothStep3(src: 5.0, dest: 10.0)
        XCTAssertEqual(result, 0.5, accuracy: 1e-10)
    }

    func testSmoothStep3_monotonicallyIncreasing() {
        let dest = 100.0
        var prevResult = -1.0
        for i in stride(from: 100.0, through: 0.0, by: -5.0) {
            let result = Interpolator.smoothStep3(src: i, dest: dest)
            XCTAssertGreaterThanOrEqual(result, prevResult,
                "smoothStep3 should be monotonically increasing as src decreases, at src=\(i)")
            prevResult = result
        }
    }

    func testSmoothStep3_formula_correctness() {
        let src = 2.0
        let dest = 8.0
        let x = (dest - src) / dest
        let expected = x * x * x * (x * (x * 6 - 15) + 10)
        let result = Interpolator.smoothStep3(src: src, dest: dest)
        XCTAssertEqual(result, expected, accuracy: 1e-10)
    }

    // MARK: - 边界行为

    func testSmoothStep2_and_3_agree_at_boundaries() {
        // 两个 smoothStep 在 x=0 和 x=1 时都应该分别返回 0 和 1
        let dest = 20.0

        // x = 0 (src == dest)
        XCTAssertEqual(Interpolator.smoothStep2(src: dest, dest: dest), 0.0, accuracy: 1e-10)
        XCTAssertEqual(Interpolator.smoothStep3(src: dest, dest: dest), 0.0, accuracy: 1e-10)

        // x = 1 (src == 0)
        XCTAssertEqual(Interpolator.smoothStep2(src: 0.0, dest: dest), 1.0, accuracy: 1e-10)
        XCTAssertEqual(Interpolator.smoothStep3(src: 0.0, dest: dest), 1.0, accuracy: 1e-10)

        // x = 0.5
        XCTAssertEqual(Interpolator.smoothStep2(src: dest / 2, dest: dest), 0.5, accuracy: 1e-10)
        XCTAssertEqual(Interpolator.smoothStep3(src: dest / 2, dest: dest), 0.5, accuracy: 1e-10)
    }

    func testLerp_largeValues() {
        let result = Interpolator.lerp(src: 0.0, dest: 1e12, trans: 0.5)
        XCTAssertEqual(result, 5e11, accuracy: 1e2)
    }
}
