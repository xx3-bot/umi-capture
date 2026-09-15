import XCTest
import simd
@testable import UMICapture

final class UltrawideRecordingWriterTests: XCTestCase {
    func testFrameMetadataEncodesStableBindingSchema() throws {
        let row = UltrawideFrameMetadata(
            schemaVersion: 1,
            frameIndex: 7,
            dataKey: "wrist_rgb_ultrawide",
            width: 640,
            height: 480,
            ultrawideTimestampSeconds: 12.503,
            matchedARKitTimestampSeconds: 12.500,
            poseMatchDeltaSeconds: 0.003,
            mp4PresentationTimeSeconds: 2.25,
            cameraIntrinsics: [
                [300, 0, 320],
                [0, 300, 240],
                [0, 0, 1]
            ],
            cameraPose: matrixRows(matrix_identity_float4x4),
            cameraWorldTransform: matrixRows(
                matrix_identity_float4x4
            ),
            interfaceOrientation: "landscape_right",
            encoded: true,
            dropReason: nil
        )

        let data = try JSONEncoder().encode(row)
        let decoded = try JSONDecoder().decode(
            UltrawideFrameMetadata.self,
            from: data
        )

        XCTAssertEqual(decoded, row)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        XCTAssertEqual(
            object["data_key"] as? String,
            "wrist_rgb_ultrawide"
        )
        XCTAssertEqual(object["ultrawide_timestamp_s"] as? Double, 12.503)
        XCTAssertEqual(object["matched_arkit_timestamp_s"] as? Double, 12.500)
        XCTAssertEqual(object["pose_match_delta_s"] as? Double, 0.003)
        XCTAssertEqual(object["mp4_pts_s"] as? Double, 2.25)
    }

    func testRecorderInjectsRoleAwareKeysIntoBothMetadataWriters()
        throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recorderSource = try String(
            contentsOf: root.appendingPathComponent(
                "UMICapture/RGBVideoRecorder.swift"
            ),
            encoding: .utf8
        )
        let ultrawideSource = try String(
            contentsOf: root.appendingPathComponent(
                "UMICapture/UltrawideRecordingWriter.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            recorderSource.contains(
                "dataKey: CaptureDataKey.main("
            )
        )
        XCTAssertTrue(
            recorderSource.contains(
                "dataKey: CaptureDataKey.ultrawide("
            )
        )
        XCTAssertTrue(
            ultrawideSource.contains("private let dataKey: String")
        )
        XCTAssertTrue(ultrawideSource.contains("dataKey: dataKey"))
        XCTAssertFalse(
            ultrawideSource.contains(
                "dataKey: \"ego_rgb_ultrawide\""
            )
        )
    }

    func testExportArtifactSetIncludesUltrawideVideoMetadataAndPreview() {
        XCTAssertTrue(
            CaptureExportPackageBuilder.rgbArtifactNames.contains(
                UltrawideRecordingWriter.videoFilename
            )
        )
        XCTAssertTrue(
            CaptureExportPackageBuilder.rgbArtifactNames.contains(
                UltrawideRecordingWriter.framesFilename
            )
        )
        XCTAssertTrue(
            CaptureExportPackageBuilder.rgbArtifactNames.contains(
                UltrawideRecordingWriter.previewFilename
            )
        )
    }

    func testStoredZIPEntriesDeclareReadableRegularFilePermissions()
        throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let archiveURL = directoryURL.appendingPathComponent("probe.zip")
        try StoredZIPArchiveWriter.write(
            entries: [
                StoredZIPEntry(
                    path: "capture_manifest.json",
                    data: Data("{}".utf8)
                ),
                StoredZIPEntry(
                    path: "README.txt",
                    data: Data("probe".utf8)
                )
            ],
            to: archiveURL
        )

        let archive = try Data(contentsOf: archiveURL)
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        let centralOffset = try XCTUnwrap(archive.range(of: signature)?.lowerBound)
        let attributeOffset = centralOffset + 38
        let externalAttributes = (0..<4).reduce(UInt32(0)) {
            $0 | UInt32(archive[attributeOffset + $1]) << UInt32(8 * $1)
        }
        XCTAssertEqual(externalAttributes, 0x81A4_0000)
    }

    private func matrixRows(
        _ matrix: simd_float4x4
    ) -> [[Float]] {
        (0..<4).map { row in
            (0..<4).map { column in matrix[column][row] }
        }
    }

}
