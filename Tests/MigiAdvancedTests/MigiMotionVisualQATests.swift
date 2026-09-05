import AppKit
import MetalKit
import XCTest
@testable import MigiAdvanced

final class MigiMotionVisualQATests: XCTestCase {
    func testExportControlledMetalMotion() throws {
        guard let path = ProcessInfo.processInfo.environment["MIGI_MOTION_QA_DIR"] else {
            throw XCTSkip("Set MIGI_MOTION_QA_DIR to export production Metal sequences.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fps = 30
        let scenarios = ProcessInfo.processInfo.environment["MIGI_MOTION_QA_SCENARIOS"]?
            .split(separator: ",").map(String.init)
            ?? ["breathing", "work-rate", "blink-gaze", "handoff", "multi-eye-blink"]
        for scenario in scenarios {
            let directory = root.appendingPathComponent(scenario, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let view = MigiFullSpriteView(
                frame: CGRect(x: 0, y: 0, width: 115, height: 135), device: device
            )
            var samples: [[String: Any]] = []
            for index in 0..<(6 * fps) {
                try autoreleasepool {
                    let elapsed = Double(index) / Double(fps)
                    let working = scenario == "work-rate" || scenario == "multi-eye-blink"
                        || (scenario == "handoff" && elapsed >= 2 && elapsed < 4)
                    let waiting = scenario == "handoff" && elapsed >= 4
                    let frame = MigiBehaviorFrame(
                        activity: working ? .thinking : (waiting ? .waiting : .idle),
                        prop: working ? .laptop : (waiting ? .phone : .none),
                        microAction: working ? .type : (scenario == "blink-gaze" ? .lookAround : .none),
                        facing: 1, isMoving: false, worldOffset: .zero,
                        bodyEnergy: 0.35 + 0.18 * sin(elapsed * 0.9), focus: 0.6,
                        blinkActive: (scenario == "blink-gaze" || scenario == "multi-eye-blink")
                            && elapsed >= 2 && elapsed < 2.12,
                        clipPlaybackScale: scenario == "work-rate"
                            ? (elapsed >= 2 && elapsed < 4 ? 1.4 : 0.75) : 1
                    )
                    let sample = try view.captureMotionQAFrame(
                        frame, time: 100_000 + elapsed,
                        deltaTime: index == 0 ? 0 : 1.0 / Double(fps),
                        gazeTarget: SIMD2(elapsed < 3 ? -0.8 : 0.8, 0.25),
                        destination: directory.appendingPathComponent(String(format: "%04d.png", index))
                    )
                    samples.append([
                        "time": elapsed, "clip": sample.clip,
                        "column": sample.column, "fps": sample.fps,
                        "rate": frame.clipPlaybackRate, "eyes": sample.eyes,
                        "eyelids": sample.eyelids
                    ])
                    if scenario == "multi-eye-blink" {
                        XCTAssertGreaterThanOrEqual(sample.eyes, 2)
                        if elapsed >= 2 && elapsed <= 2.30 {
                            XCTAssertEqual(sample.fps, 60)
                        }
                    }
                }
            }
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("samples.json"))
        }
    }
}
