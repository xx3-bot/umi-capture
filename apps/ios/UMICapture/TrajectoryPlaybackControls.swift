import SwiftUI
import simd

struct TrajectoryPlaybackFrame: Equatable {
    let visibleSampleCount: Int
    let headSample: TrajectoryPoseSample?
    let elapsedTimeSeconds: TimeInterval
}

enum TrajectoryPlaybackTimeline {
    static func recordedDuration(
        samples: [TrajectoryPoseSample]
    ) -> TimeInterval? {
        guard samples.count > 1 else {
            return nil
        }
        var previous = -Double.infinity
        for sample in samples {
            guard let elapsed = sample.elapsedTimeSeconds,
                  elapsed.isFinite,
                  elapsed >= 0,
                  elapsed >= previous,
                  validOrientation(sample.orientationXYZW)
            else {
                return nil
            }
            previous = elapsed
        }
        guard previous > 0 else {
            return nil
        }
        return previous
    }

    static func frame(
        samples: [TrajectoryPoseSample],
        elapsedTimeSeconds: TimeInterval
    ) -> TrajectoryPlaybackFrame {
        guard !samples.isEmpty,
              let duration = recordedDuration(samples: samples)
        else {
            return TrajectoryPlaybackFrame(
                visibleSampleCount: samples.count,
                headSample: nil,
                elapsedTimeSeconds: 0
            )
        }

        let elapsed = min(
            max(0, elapsedTimeSeconds),
            duration
        )
        if elapsed >= duration {
            return TrajectoryPlaybackFrame(
                visibleSampleCount: samples.count,
                headSample: nil,
                elapsedTimeSeconds: duration
            )
        }

        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            let middleTime =
                samples[middle].elapsedTimeSeconds ?? 0
            if middleTime <= elapsed {
                low = middle + 1
            } else {
                high = middle
            }
        }

        let lowerIndex = max(0, low - 1)
        let upperIndex = min(samples.count - 1, low)
        let lower = samples[lowerIndex]
        let upper = samples[upperIndex]
        guard lowerIndex != upperIndex,
              let lowerTime = lower.elapsedTimeSeconds,
              let upperTime = upper.elapsedTimeSeconds,
              upperTime > lowerTime
        else {
            return TrajectoryPlaybackFrame(
                visibleSampleCount: lowerIndex + 1,
                headSample: nil,
                elapsedTimeSeconds: elapsed
            )
        }

        let fraction = Float(
            (elapsed - lowerTime) / (upperTime - lowerTime)
        )
        guard fraction > 0.0001 else {
            return TrajectoryPlaybackFrame(
                visibleSampleCount: lowerIndex + 1,
                headSample: nil,
                elapsedTimeSeconds: elapsed
            )
        }

        let position = simd_mix(
            lower.position,
            upper.position,
            SIMD3<Float>(repeating: fraction)
        )
        let orientation = interpolatedOrientation(
            from: lower.orientationXYZW,
            to: upper.orientationXYZW,
            fraction: fraction
        )
        // Interpolate the stored camera-forward direction so playback follows
        // the archived acquisition semantics exactly.
        let cameraForward = simd_normalize(
            simd_mix(
                lower.cameraForward,
                upper.cameraForward,
                SIMD3<Float>(repeating: fraction)
            )
        )

        return TrajectoryPlaybackFrame(
            visibleSampleCount: lowerIndex + 1,
            headSample: TrajectoryPoseSample(
                position: position,
                cameraForward: cameraForward,
                elapsedTimeSeconds: elapsed,
                orientationXYZW: orientation
            ),
            elapsedTimeSeconds: elapsed
        )
    }

    private static func interpolatedOrientation(
        from start: SIMD4<Float>?,
        to end: SIMD4<Float>?,
        fraction: Float
    ) -> SIMD4<Float>? {
        guard validOrientation(start),
              validOrientation(end),
              let start,
              let end
        else {
            return nil
        }
        let result = simd_slerp(
            simd_quatf(vector: start),
            simd_quatf(vector: end),
            fraction
        )
        return SIMD4<Float>(
            result.imag.x,
            result.imag.y,
            result.imag.z,
            result.real
        )
    }

    private static func validOrientation(
        _ orientation: SIMD4<Float>?
    ) -> Bool {
        guard let orientation,
              orientation.x.isFinite,
              orientation.y.isFinite,
              orientation.z.isFinite,
              orientation.w.isFinite
        else {
            return false
        }
        let norm = simd_length(orientation)
        return norm > 0.99 && norm < 1.01
    }
}

struct TrajectoryPlaybackControls: View {
    let samples: [TrajectoryPoseSample]
    let language: AppLanguage
    @Binding var visibleSampleCount: Int
    @Binding var playbackHeadSample: TrajectoryPoseSample?
    @Binding var isPlaying: Bool

    @State private var playbackTimer: Timer?
    @State private var playbackPosition: TimeInterval = 0
    @State private var playbackRate = 1.0
    @State private var previousTickUptime: TimeInterval?

    private let estimatedPlaybackDuration: TimeInterval = 6
    private let playbackFramesPerSecond = 60.0

    private var recordedDuration: TimeInterval? {
        TrajectoryPlaybackTimeline.recordedDuration(
            samples: samples
        )
    }

    private var playbackDuration: TimeInterval {
        recordedDuration ?? estimatedPlaybackDuration
    }

    private var hasRecordedTiming: Bool {
        recordedDuration != nil
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button {
                    restartPlayback()
                } label: {
                    Label(
                        language.text("Replay", "重播"),
                        systemImage: "backward.end.fill"
                    )
                }

                Button {
                    if isPlaying {
                        resetToBeginning()
                    } else {
                        if playbackPosition >= playbackDuration {
                            resetToBeginning()
                        }
                        isPlaying = true
                    }
                } label: {
                    Label(
                        isPlaying
                            ? language.text("Stop playback", "停止回放")
                            : language.text("Play", "播放"),
                        systemImage: isPlaying
                            ? "stop.fill"
                            : "play.fill"
                    )
                }
                .disabled(samples.count < 2)

                Spacer()

                Text(playbackPositionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))

            Slider(
                value: Binding(
                    get: {
                        playbackPosition
                    },
                    set: {
                        playbackPosition = $0
                        applyPlaybackPosition()
                    }
                ),
                in: 0...max(0.001, playbackDuration),
                onEditingChanged: { isEditing in
                    if isEditing {
                        isPlaying = false
                    }
                }
            )
            .tint(.cyan)
            .disabled(samples.count < 2)
            .accessibilityLabel(
                language.text(
                    "Trajectory playback time",
                    "轨迹回放时间"
                )
            )

            HStack(spacing: 10) {
                Label(
                    hasRecordedTiming
                        ? language.text(
                            "Recorded timing",
                            "原始时间轴"
                        )
                        : language.text(
                            "Estimated timing",
                            "估算时间"
                        ),
                    systemImage: hasRecordedTiming
                        ? "clock.badge.checkmark"
                        : "clock.badge.questionmark"
                )
                .foregroundStyle(
                    hasRecordedTiming ? .green : .orange
                )

                Spacer()

                Picker(
                    language.text("Playback speed", "回放速度"),
                    selection: $playbackRate
                ) {
                    Text("0.5×").tag(0.5)
                    Text("1×").tag(1.0)
                    Text("2×").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
            }
            .font(.caption.weight(.semibold))
        }
        .onAppear {
            showCompleteTrajectory()
        }
        .onChange(of: samples.count) { oldCount, newCount in
            if !isPlaying,
               visibleSampleCount >= oldCount {
                showCompleteTrajectory()
            } else {
                visibleSampleCount = min(
                    visibleSampleCount,
                    newCount
                )
            }
        }
        .onChange(of: isPlaying) { _, shouldPlay in
            if shouldPlay {
                startTimer()
            } else {
                stopTimer()
            }
        }
        .onDisappear {
            isPlaying = false
            stopTimer()
        }
    }

    private var playbackPositionText: String {
        "\(formatTime(playbackPosition))"
            + " / \(formatTime(playbackDuration))"
    }

    private func formatTime(_ value: TimeInterval) -> String {
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    private func restartPlayback() {
        resetToBeginning()
        isPlaying = samples.count > 1
    }

    private func resetToBeginning() {
        playbackPosition = 0
        applyPlaybackPosition()
    }

    private func showCompleteTrajectory() {
        playbackPosition = playbackDuration
        visibleSampleCount = samples.count
        playbackHeadSample = nil
    }

    private func applyPlaybackPosition() {
        guard hasRecordedTiming else {
            let fraction = playbackDuration > 0
                ? playbackPosition / playbackDuration
                : 1
            visibleSampleCount = min(
                samples.count,
                max(
                    samples.isEmpty ? 0 : 1,
                    Int(
                        floor(
                            fraction * Double(samples.count)
                        )
                    )
                )
            )
            playbackHeadSample = nil
            return
        }

        let frame = TrajectoryPlaybackTimeline.frame(
            samples: samples,
            elapsedTimeSeconds: playbackPosition
        )
        visibleSampleCount = frame.visibleSampleCount
        playbackHeadSample = frame.headSample
    }

    private func startTimer() {
        stopTimer()
        guard samples.count > 1 else {
            isPlaying = false
            return
        }
        previousTickUptime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(
            timeInterval: 1.0 / playbackFramesPerSecond,
            repeats: true
        ) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let previous = previousTickUptime ?? now
            previousTickUptime = now
            playbackPosition = min(
                playbackDuration,
                playbackPosition
                    + max(0, now - previous) * playbackRate
            )
            applyPlaybackPosition()
            if playbackPosition >= playbackDuration {
                isPlaying = false
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        previousTickUptime = nil
    }
}
