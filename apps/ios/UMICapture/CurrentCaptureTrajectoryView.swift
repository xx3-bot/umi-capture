import SwiftUI
import simd

struct CurrentCaptureTrajectoryView: View {
    @ObservedObject var viewController: ViewController
    let language: AppLanguage

    @State private var yaw: CGFloat = -0.7
    @State private var pitch: CGFloat = 0.45
    @State private var dragStartYaw: CGFloat = -0.7
    @State private var dragStartPitch: CGFloat = 0.45
    @State private var visibleSampleCount = 0
    @State private var playbackHeadSample: TrajectoryPoseSample?
    @State private var isTrajectoryPlaying = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    metricCard(
                        title: language.text("STATE", "状态"),
                        value: captureState,
                        color: captureColor
                    )
                    metricCard(
                        title: language.text("POINTS", "点数"),
                        value: "\(viewController.trajectorySamples.count)",
                        color: .cyan
                    )
                    metricCard(
                        title: language.text(
                            "FROM ORIGIN",
                            "距原点"
                        ),
                        value: String(
                            format: "%.3f m",
                            currentDisplacement
                        ),
                        color: .orange
                    )
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.black)

                    if viewController.trajectorySamples.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "figure.walk.motion")
                                .font(.system(size: 34))
                            Text(
                                language.text(
                                    "Press Start to begin a capture",
                                    "点击开始进行采集"
                                )
                            )
                                .font(.headline)
                            Text(
                                language.text(
                                    "The current trajectory is cleared by Reset.",
                                    "重置会清除当前未完成轨迹。"
                                )
                            )
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.white)
                    } else {
                        TrajectoryPlot3D(
                            samples: visualizationSamples,
                            yaw: yaw,
                            pitch: pitch,
                            visibleSampleCount: visibleSampleCount,
                            playbackHeadSample: playbackHeadSample,
                            startLabel: language.text(
                                "START",
                                "起点"
                            ),
                            endLabel: language.text(
                                "END",
                                "终点"
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    Text(
                        language.text(
                            "Drag to rotate",
                            "拖动旋转"
                        )
                    )
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(10)
                }
                .contentShape(Rectangle())
                .gesture(rotationGesture)

                TrajectoryPlaybackControls(
                    samples: visualizationSamples,
                    language: language,
                    visibleSampleCount: $visibleSampleCount,
                    playbackHeadSample: $playbackHeadSample,
                    isPlaying: $isTrajectoryPlaying
                )

                HStack(spacing: 16) {
                    axisLegend(
                        color: .red,
                        label: language.text("−X up", "−X 向上")
                    )
                    axisLegend(color: .green, label: "Y")
                    axisLegend(color: .blue, label: "Z")
                    poseLegend
                    Spacer()
                    Text(
                        language.text(
                            "Gravity aligned",
                            "重力对齐"
                        )
                    )
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .navigationTitle(
                language.text("3D Trajectory", "三维轨迹")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        yaw = -0.7
                        pitch = 0.45
                        dragStartYaw = yaw
                        dragStartPitch = pitch
                    } label: {
                        Image(systemName: "viewfinder")
                    }
                    .accessibilityLabel(
                        language.text("Reset view", "重置视角")
                    )
                }
            }
        }
    }

    private var currentDisplacement: Float {
        guard let sample = visualizationSamples.last else {
            return 0
        }
        return simd_length(sample.position)
    }

    private var visualizationSamples: [TrajectoryPoseSample] {
        TrajectoryVisualizationPolicy.samples(
            from: viewController.trajectorySamples,
            displayFrame: viewController.trajectoryArchiveDisplayFrame,
            captureRole: viewController.activeCaptureRole,
            calibrationID: viewController.calibrationID
        )
    }

    private var captureState: String {
        if viewController.isStreaming {
            return language.text("LIVE", "采集中")
        }
        if viewController.isStarting {
            return language.text("STARTING", "即将开始")
        }
        if viewController.isCalibrating {
            return language.text("PREPARING", "准备中")
        }
        if viewController.isCalibrationReady {
            return language.text("ARMED", "已就绪")
        }
        return language.text("READY", "就绪")
    }

    private var captureColor: Color {
        if viewController.isStreaming {
            return .green
        }
        if viewController.isCalibrationReady {
            return .orange
        }
        return .secondary
    }

    private var rotationGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                yaw = dragStartYaw + value.translation.width * 0.01
                pitch = min(
                    1.2,
                    max(
                        -1.2,
                        dragStartPitch - value.translation.height * 0.01
                    )
                )
            }
            .onEnded { _ in
                dragStartYaw = yaw
                dragStartPitch = pitch
            }
    }

    private func metricCard(
        title: String,
        value: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func axisLegend(
        color: Color,
        label: String
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.bold())
        }
    }

    private var poseLegend: some View {
        HStack(spacing: 4) {
            Image(systemName: "move.3d")
                .font(.caption.bold())
                .foregroundColor(.white)
            Text(language.text("Pose XYZ", "姿态 XYZ"))
                .font(.caption.bold())
        }
        .accessibilityLabel(
            language.text(
                "Framewise 6D pose orientation axes",
                "逐帧六维姿态方向轴"
            )
        )
    }
}
