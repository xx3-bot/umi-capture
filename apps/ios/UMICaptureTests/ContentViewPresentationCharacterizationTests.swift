import CryptoKit
import SwiftUI
import XCTest
@testable import UMICapture

@MainActor
final class ContentViewPresentationCharacterizationTests: XCTestCase {
    private let renderSize = CGSize(width: 320, height: 240)

    func testNewCaptureHealthLabelsHaveChineseTranslations() {
        let language = AppLanguage.simplifiedChinese
        XCTAssertEqual(
            language.localizedThermalState("Warm"),
            "设备偏热"
        )
        XCTAssertEqual(
            language.localizedFinalizationStage(.packaging),
            "正在生成采集包"
        )
        XCTAssertEqual(
            language.localizedRuntimeStatus(
                "Capture package timed out — recovery files retained"
            ),
            "采集包生成超时——已保留恢复文件"
        )
    }

    func testTrajectoryPlotDefaultsRemainStable() {
        let samples = makeTrajectorySamples()
        let plot = TrajectoryPlot3D(
            samples: samples,
            yaw: -0.7,
            pitch: 0.45
        )

        XCTAssertEqual(plot.samples, samples)
        XCTAssertEqual(plot.yaw, -0.7)
        XCTAssertEqual(plot.pitch, 0.45)
        XCTAssertNil(plot.visibleSampleCount)
        XCTAssertNil(plot.playbackHeadSample)
        XCTAssertEqual(plot.startLabel, "START")
        XCTAssertEqual(plot.endLabel, "END")
    }

    func testTrajectoryPlotExplicitInputsRemainStable() {
        let samples = makeTrajectorySamples()
        let playbackHead = TrajectoryPoseSample(
            position: SIMD3<Float>(0.55, 0.18, -0.75),
            cameraForward: SIMD3<Float>(0.2, -0.1, -0.97),
            elapsedTimeSeconds: 1.5,
            orientationXYZW: SIMD4<Float>(0, 0, 0, 1)
        )
        let plot = TrajectoryPlot3D(
            samples: samples,
            yaw: 0.35,
            pitch: -0.25,
            visibleSampleCount: 2,
            playbackHeadSample: playbackHead,
            startLabel: "BEGIN",
            endLabel: "FINISH"
        )

        XCTAssertEqual(plot.samples, samples)
        XCTAssertEqual(plot.visibleSampleCount, 2)
        XCTAssertEqual(plot.playbackHeadSample, playbackHead)
        XCTAssertEqual(plot.startLabel, "BEGIN")
        XCTAssertEqual(plot.endLabel, "FINISH")
    }

    func testTrajectoryPlotRenderGoldensRemainStable() throws {
        let samples = makeTrajectorySamples()

        let emptyDigest = try renderDigest(
            TrajectoryPlot3D(
                samples: [],
                yaw: -0.7,
                pitch: 0.45
            )
        )
        let completeDigest = try renderDigest(
            TrajectoryPlot3D(
                samples: samples,
                yaw: -0.7,
                pitch: 0.45,
                startLabel: "START",
                endLabel: "END"
            )
        )
        let playbackDigest = try renderDigest(
            TrajectoryPlot3D(
                samples: samples,
                yaw: 0.35,
                pitch: -0.25,
                visibleSampleCount: 2,
                playbackHeadSample: TrajectoryPoseSample(
                    position: SIMD3<Float>(0.55, 0.18, -0.75),
                    cameraForward: SIMD3<Float>(0.2, -0.1, -0.97)
                ),
                startLabel: "BEGIN",
                endLabel: "FINISH"
            )
        )

        XCTAssertEqual(
            emptyDigest,
            "d7a27577856c8d9f685729f322fbd1ae0d67dab4e52673d32567d591e1335b7c"
        )
        XCTAssertEqual(
            completeDigest,
            "266290533894ab8f52c899f1ae57684ef1522d63cdca38fad5c1eb19c4364bac"
        )
        XCTAssertEqual(
            playbackDigest,
            "fc6011db770a8ebe1ee0b646a5471d9342e1e382cff3759589981337b56f5837"
        )
    }

    func testAxisPresentationValuesAndRenderGoldenRemainStable() throws {
        let axes = VIOAxisDirections(
            x: VIOAxisDirection(
                horizontal: 0.8,
                vertical: -0.35,
                depth: 0.2
            ),
            y: VIOAxisDirection(
                horizontal: -0.1,
                vertical: -0.2,
                depth: 0.95
            ),
            z: VIOAxisDirection(
                horizontal: -0.45,
                vertical: 0.75,
                depth: -0.7
            )
        )

        XCTAssertEqual(axes.x.horizontal, 0.8)
        XCTAssertEqual(axes.y.depth, 0.95)
        XCTAssertEqual(axes.z.vertical, 0.75)
        XCTAssertEqual(
            try renderDigest(VIOAxesOverlay(axes: axes)),
            "f396ec250a5ef20584cfa64bca6cbdfd0806e6da6f757d34a917938ebb8e47ee"
        )
    }

    func testUMICaptureOnboardingAndPermanentAboutSourceContracts() throws {
        let root = repositoryRoot
        let launch = try source(
            at: root.appendingPathComponent(
                "UMICapture/LaunchGateView.swift"
            )
        )
        let drawer = try source(
            at: root.appendingPathComponent(
                "UMICapture/CaptureDrawerView.swift"
            )
        )
        let provenance = try source(
            at: root.appendingPathComponent(
                "UMICapture/SoftwareProvenance.swift"
            )
        )

        XCTAssertTrue(
            launch.contains("UMICapture.sourceProvenanceAcknowledged")
        )
        XCTAssertTrue(launch.contains("UMICapture.tutorialCompleted"))
        XCTAssertTrue(launch.contains("已了解并继续"))
        XCTAssertTrue(launch.contains("Camera access"))
        XCTAssertTrue(launch.contains("Local Network access"))
        XCTAssertTrue(launch.contains("default RGB streams"))
        XCTAssertTrue(launch.contains("estimated-duration"))
        XCTAssertTrue(launch.contains("local capture library"))
        XCTAssertTrue(drawer.contains("About UMI Capture"))
        XCTAssertTrue(drawer.contains("UMICaptureAboutView"))
        XCTAssertTrue(
            launch.contains(
                "private var language: AppLanguage = .simplifiedChinese"
            )
        )
        let content = try source(
            at: root.appendingPathComponent("UMICapture/ContentView.swift")
        )
        XCTAssertTrue(
            content.contains(
                "private var language: AppLanguage = .simplifiedChinese"
            )
        )

        for expected in [
            "Xinrui Xiong",
            "Universal Manipulation Interface",
            "UMI on Legs",
            "iPhUMI",
            "iPhoneVIO",
            "https://github.com/xx3-bot/umi-capture/issues",
            "independently implemented ARKit-based capture and processing tool"
        ] {
            XCTAssertTrue(provenance.contains(expected), expected)
        }
    }

    func testSynchronizationBarDirectlyRequestsAndRoleLivesInDrawer()
        throws {
        let root = repositoryRoot
        let content = try source(
            at: root.appendingPathComponent("UMICapture/ContentView.swift")
        )
        let drawer = try source(
            at: root.appendingPathComponent(
                "UMICapture/CaptureDrawerView.swift"
            )
        )
        let controls = try XCTUnwrap(
            content.range(of: "private var homeCaptureControls")
        )
        let bar = try XCTUnwrap(
            content.range(
                of: "synchronizationStatusBar",
                range: controls.lowerBound..<content.endIndex
            )
        )
        let primary = try XCTUnwrap(
            content.range(
                of: "primaryControls",
                range: bar.upperBound..<content.endIndex
            )
        )
        let barDefinition = try XCTUnwrap(
            content.range(of: "private var synchronizationStatusBar")
        )
        let buttonTitleDefinition = try XCTUnwrap(
            content.range(
                of: "private var synchronizedCaptureButtonTitle",
                range: barDefinition.upperBound..<content.endIndex
            )
        )
        let synchronizationBlock = String(
            content[
                barDefinition.lowerBound..<buttonTitleDefinition.lowerBound
            ]
        )

        XCTAssertLessThan(
            content.distance(from: content.startIndex, to: bar.lowerBound),
            content.distance(
                from: content.startIndex,
                to: primary.lowerBound
            )
        )
        XCTAssertEqual(
            content.components(
                separatedBy: "showsSynchronizedSetup = true"
            ).count - 1,
            0
        )
        XCTAssertTrue(
            synchronizationBlock.contains(
                "viewController.requestSynchronizedCapture()"
            )
        )
        XCTAssertTrue(
            synchronizationBlock.contains(
                "switch synchronizedPreparationButtonAction"
            )
        )
        XCTAssertTrue(
            synchronizationBlock.contains(
                ".disabled(synchronizedPreparationButtonAction == .unavailable)"
            )
        )
        XCTAssertTrue(synchronizationBlock.contains("link.circle.fill"))
        XCTAssertTrue(
            synchronizationBlock.contains(
                ".frame(width: 340, height: 56)"
            )
        )
        XCTAssertFalse(drawer.contains("requestSynchronizedCapture"))
        XCTAssertFalse(drawer.contains("requestGroupCommand"))
        XCTAssertTrue(drawer.contains("captureProfileID"))
        XCTAssertTrue(drawer.contains("本机角色"))

        let manager = try source(
            at: root.appendingPathComponent(
                "UMICapture/ARSessionManager.swift"
            )
        )
        XCTAssertTrue(manager.contains("retriesPendingRequest"))
        XCTAssertTrue(
            manager.contains("clearPendingGroupPreparationRequest()")
        )
        for forbidden in ["Pause", "Resume"] {
            XCTAssertFalse(content.contains(forbidden), forbidden)
            XCTAssertFalse(drawer.contains(forbidden), forbidden)
            XCTAssertFalse(
                try source(
                    at: root.appendingPathComponent(
                        "UMICapture/LaunchGateView.swift"
                    )
                ).contains(forbidden),
                forbidden
            )
        }
    }

    func testHandEgoPreviewUsesBoundedLifecycleAndDraggableOverlay()
        throws {
        let root = repositoryRoot
        let content = try source(
            at: root.appendingPathComponent("UMICapture/ContentView.swift")
        )
        let manager = try source(
            at: root.appendingPathComponent(
                "UMICapture/ARSessionManager.swift"
            )
        )
        let socket = try source(
            at: root.appendingPathComponent("UMICapture/SocketClient.swift")
        )

        for expected in [
            "UMICapture.egoPreview.portrait.x",
            "UMICapture.egoPreview.landscape.y",
            "EgoPreviewLayoutPolicy.clampedCenter",
            "DragGesture(minimumDistance: 1)",
            "EGO · STALE",
            "EGO · LIVE",
            ".aspectRatio(contentMode: .fit)"
        ] {
            XCTAssertTrue(content.contains(expected), expected)
        }
        for expected in [
            "egoPreviewEncodingInFlight",
            "umi_capture.ego-preview.encode",
            "umi_capture.ego-preview.decode",
            "EgoPreviewThumbnailPolicy.maximumJPEGBytes",
            "egoPreviewLifecycleToken",
            "expectedEgoPreviewDeviceID",
            "maybeSendEgoPreview(",
            "receiveEgoPreviewFrame("
        ] {
            XCTAssertTrue(manager.contains(expected), expected)
        }
        XCTAssertTrue(socket.contains("sendEgoPreviewFrame"))
        XCTAssertTrue(socket.contains("onEgoPreviewFrame"))
        XCTAssertTrue(socket.contains("CaptureCoordinationProtocol.egoPreviewFrame"))
    }

    func testWarmIdleKeepsARKitRunningButSkipsHeavyFrameWork()
        throws {
        let manager = try source(
            at: repositoryRoot.appendingPathComponent(
                "UMICapture/ARSessionManager.swift"
            )
        )
        let warmStart = try XCTUnwrap(
            manager.range(of: "private func enterWarmIdle()")
        )
        let suspendStart = try XCTUnwrap(
            manager.range(
                of: "private func suspendARSession()",
                range: warmStart.upperBound..<manager.endIndex
            )
        )
        let warmBlock = String(
            manager[warmStart.lowerBound..<suspendStart.lowerBound]
        )
        XCTAssertFalse(warmBlock.contains("session.pause()"))
        XCTAssertTrue(warmBlock.contains("releaseTransientCaches()"))

        let frameStart = try XCTUnwrap(
            manager.range(of: "func session(_ session: ARSession, didUpdate")
        )
        let performanceStart = try XCTUnwrap(
            manager.range(
                of: "private func updatePerformanceIfNeeded",
                range: frameStart.upperBound..<manager.endIndex
            )
        )
        let frameBlock = String(
            manager[frameStart.lowerBound..<performanceStart.lowerBound]
        )
        XCTAssertTrue(frameBlock.contains("guard shouldProcessCaptureFrame"))
        XCTAssertTrue(frameBlock.contains("60 Hz ARKit 热待机"))
        XCTAssertTrue(manager.contains("_ = ensureARSessionRunning()"))
    }

    func testRGBRecorderFailureCannotTerminateVIOInStatusCallback()
        throws {
        let manager = try source(
            at: repositoryRoot.appendingPathComponent(
                "UMICapture/ARSessionManager.swift"
            )
        )
        let start = try XCTUnwrap(
            manager.range(of: "    private func setupRGBVideoRecorder()")
        )
        let end = try XCTUnwrap(
            manager.range(
                of: "    private func observeApplicationLifecycle()",
                range: start.upperBound..<manager.endIndex
            )
        )
        let callback = String(
            manager[start.lowerBound..<end.lowerBound]
        )

        XCTAssertTrue(callback.contains("rgbRecorderStatus = status"))
        XCTAssertFalse(callback.contains("isStreaming ="))
        XCTAssertFalse(callback.contains("interruptCapture("))
        XCTAssertFalse(callback.contains("endCurrentCapture("))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func makeTrajectorySamples() -> [TrajectoryPoseSample] {
        [
            TrajectoryPoseSample(
                position: SIMD3<Float>(0, 0, 0),
                cameraForward: SIMD3<Float>(0, 0, -1),
                elapsedTimeSeconds: 0
            ),
            TrajectoryPoseSample(
                position: SIMD3<Float>(0.25, 0.08, -0.3),
                cameraForward: SIMD3<Float>(0.1, 0, -0.99),
                elapsedTimeSeconds: 0.5
            ),
            TrajectoryPoseSample(
                position: SIMD3<Float>(0.5, 0.16, -0.65),
                cameraForward: SIMD3<Float>(0.2, -0.05, -0.97),
                elapsedTimeSeconds: 1.0
            ),
            TrajectoryPoseSample(
                position: SIMD3<Float>(0.75, 0.22, -0.95),
                cameraForward: SIMD3<Float>(0.3, -0.1, -0.94),
                elapsedTimeSeconds: 1.5
            )
        ]
    }

    private func renderDigest<Content: View>(
        _ content: Content
    ) throws -> String {
        let renderer = ImageRenderer(
            content: content
                .frame(width: renderSize.width, height: renderSize.height)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 1
        renderer.isOpaque = true

        let image = try XCTUnwrap(renderer.cgImage)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
