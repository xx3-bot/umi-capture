#!/usr/bin/env python3
"""Static product-boundary tests for the public UMI Capture iOS source."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "apps/ios"
PROJECT = IOS / "UMICapture.xcodeproj/project.pbxproj"


class IOSProductBoundaryTests(unittest.TestCase):
    def test_project_uses_neutral_signing_identity(self) -> None:
        text = PROJECT.read_text(encoding="utf-8")
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.example.UMICapture;", text)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.example.UMICaptureTests;", text)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER = com.example.UMICaptureUITests;", text)
        self.assertTrue((IOS / "UMICapture.xcworkspace").is_dir())
        self.assertFalse((IOS / "DeepUMI.xcodeproj").exists())
        self.assertNotIn("com.xinruixiong", text)
        for line in text.splitlines():
            if "DEVELOPMENT_TEAM =" in line:
                self.assertIn('DEVELOPMENT_TEAM = "";', line)

    def test_removed_feature_sources_are_absent(self) -> None:
        forbidden = {
            "IPhUMIDepthRecordingWriter.swift",
            "NearbyInteractionCalibration.swift",
            "RoomPlanScanAssistant.swift",
            "SharedWorldReferenceTarget.swift",
            "SpatialMeshSimplifier.swift",
            "SpatialReconstructionEvidenceRecorder.swift",
            "SpatialScanGuidance.swift",
            "SpatialScanManager.swift",
            "SpatialScanModels.swift",
            "SpatialScanPerformance.swift",
            "SpatialScanView.swift",
            "VisionBoardCalibration.swift",
        }
        names = {path.name for path in (IOS / "UMICapture").glob("*.swift")}
        self.assertTrue(forbidden.isdisjoint(names), sorted(forbidden & names))

    def test_public_provenance_is_independent_and_not_derivative(self) -> None:
        text = (IOS / "UMICapture/SoftwareProvenance.swift").read_text(encoding="utf-8")
        self.assertIn("independently implemented", text)
        self.assertIn('productName = "UMI Capture"', text)
        self.assertNotIn("derivative visual-inertial", text)
        self.assertNotIn("originalDevelopers", text)
        self.assertNotIn("secondaryDeveloper", text)

    def test_action_bus_has_no_upstream_ar_manager_type(self) -> None:
        self.assertTrue((IOS / "UMICapture/CaptureActionBus.swift").is_file())
        self.assertFalse((IOS / "UMICapture/ARManager.swift").exists())
        swift = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (IOS / "UMICapture").glob("*.swift")
        )
        self.assertNotIn("ARManager", swift)


if __name__ == "__main__":
    unittest.main()
