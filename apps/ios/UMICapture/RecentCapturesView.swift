import AVKit
import SwiftUI

struct RecentCapturesView: View {
    @ObservedObject var library: CaptureLibrary
    let language: AppLanguage

    @State private var trajectoryPreview: TrajectoryCaptureRecord?
    @State private var rgbPreview: RGBCaptureRecord?
    @State private var pendingDeletion: CaptureDeletion?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if library.trajectories.isEmpty {
                        ContentUnavailableView(
                            language.text(
                                "No completed trajectories",
                                "暂无已完成轨迹"
                            ),
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                            description: Text(
                                language.text(
                                    "A trajectory is saved after End or remote Stop.",
                                    "点击结束或收到远程 Stop 后保存轨迹。"
                                )
                            )
                        )
                    } else {
                        ForEach(library.trajectories) { record in
                            trajectoryCard(record)
                                .swipeActions {
                                    Button(
                                        role: .destructive
                                    ) {
                                        pendingDeletion =
                                            .trajectory(record)
                                    } label: {
                                        Label(
                                            language.text(
                                                "Delete",
                                                "删除"
                                            ),
                                            systemImage: "trash"
                                        )
                                    }
                                }
                        }
                    }
                } header: {
                    Text(
                        language.text(
                            "TRAJECTORIES · ",
                            "轨迹 · "
                        )
                            + "\(library.trajectories.count)"
                    )
                }

                Section {
                    if library.rgbVideos.isEmpty {
                        ContentUnavailableView(
                            language.text(
                                "No finalized RGB videos",
                                "暂无已完成 RGB 视频"
                            ),
                            systemImage: "video.slash",
                            description: Text(
                                language.text(
                                    "Each finalized recording segment appears here.",
                                    "每段完成保存的录像都会显示在这里。"
                                )
                            )
                        )
                    } else {
                        ForEach(library.rgbVideos) { record in
                            rgbCard(record)
                                .swipeActions {
                                    Button(
                                        role: .destructive
                                    ) {
                                        pendingDeletion =
                                            .rgbVideo(record)
                                    } label: {
                                        Label(
                                            language.text(
                                                "Delete",
                                                "删除"
                                            ),
                                            systemImage: "trash"
                                        )
                                    }
                                }
                        }
                    }
                } header: {
                    Text(
                        language.text(
                            "RGB VIDEOS · ",
                            "RGB 视频 · "
                        )
                            + "\(library.rgbVideos.count)"
                    )
                }

                Section {
                    if library.exportPackages.isEmpty {
                        Text(
                            language.text(
                                "No verified export packages",
                                "暂无已验证导出包"
                            )
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(library.exportPackages) { record in
                            exportPackageCard(record)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        pendingDeletion =
                                            .exportPackage(record)
                                    } label: {
                                        Label(
                                            language.text("Delete", "删除"),
                                            systemImage: "trash"
                                        )
                                    }
                                }
                        }
                    }
                } header: {
                    Text(
                        language.text("EXPORT PACKAGES · ", "导出包 · ")
                            + "\(library.exportPackages.count)"
                    )
                }

                if !library.exportRecovery.isEmpty {
                    Section(
                        language.text("RECOVERY", "恢复诊断")
                    ) {
                        ForEach(library.exportRecovery) { record in
                            recoveryCard(record)
                                .swipeActions {
                                    if record.isDeletionEligible {
                                        Button(role: .destructive) {
                                            pendingDeletion =
                                                .exportRecovery(record)
                                        } label: {
                                            Label(
                                                language.text(
                                                    "Delete",
                                                    "删除"
                                                ),
                                                systemImage: "trash"
                                            )
                                        }
                                    }
                                }
                        }
                    }
                }

                if !library.diagnosticErrors.isEmpty {
                    Section(
                        language.text("DIAGNOSTICS", "诊断信息")
                    ) {
                        ForEach(
                            Array(
                                library.diagnosticErrors
                                    .prefix(5)
                                    .enumerated()
                            ),
                            id: \.offset
                        ) { _, message in
                            Label(
                                message,
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(
                language.text("Recent Captures", "最近采集")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            library.refresh()
                        } label: {
                            Label(
                                language.text("Refresh", "刷新"),
                                systemImage: "arrow.clockwise"
                            )
                        }

                        Divider()

                        Button(role: .destructive) {
                            pendingDeletion = .allTrajectories
                        } label: {
                            Label(
                                language.text(
                                    "Delete All Trajectories",
                                    "删除全部轨迹"
                                ),
                                systemImage: "trash"
                            )
                        }
                        .disabled(library.trajectories.isEmpty)

                        Button(role: .destructive) {
                            pendingDeletion = .allRGBVideos
                        } label: {
                            Label(
                                language.text(
                                    "Delete All RGB Videos",
                                    "删除全部 RGB 视频"
                                ),
                                systemImage: "trash"
                            )
                        }
                        .disabled(library.rgbVideos.isEmpty)

                        Button(role: .destructive) {
                            pendingDeletion = .allCaptures
                        } label: {
                            Label(
                                language.text(
                                    "Delete All Captures",
                                    "删除全部采集"
                                ),
                                systemImage: "trash.slash"
                            )
                        }
                        .disabled(
                            library.trajectories.isEmpty
                                && library.rgbVideos.isEmpty
                        )
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(
                        language.text(
                            "Capture library actions",
                            "采集库操作"
                        )
                    )
                }
            }
            .onAppear {
                library.refresh()
            }
            .sheet(item: $trajectoryPreview) { record in
                ArchivedTrajectoryPreviewView(
                    record: record,
                    language: language
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $rgbPreview) { record in
                RGBLibraryVideoPreviewView(
                    record: record,
                    language: language
                )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .alert(
                pendingDeletion?.title(language) ?? "",
                isPresented: Binding(
                    get: {
                        pendingDeletion != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            pendingDeletion = nil
                        }
                    }
                )
            ) {
                Button(
                    pendingDeletion?.buttonTitle(language)
                        ?? language.text("Delete", "删除"),
                    role: .destructive
                ) {
                    performPendingDeletion()
                }
                Button(
                    language.text("Cancel", "取消"),
                    role: .cancel
                ) {
                    pendingDeletion = nil
                }
            } message: {
                Text(
                    pendingDeletion?.message(language) ?? ""
                )
            }
        }
        .accessibilityIdentifier("umi_capture.capture.recent-captures")
    }

    private func performPendingDeletion() {
        switch pendingDeletion {
        case .trajectory(let record):
            library.deleteTrajectory(record)
        case .rgbVideo(let record):
            library.deleteRGBVideo(record)
        case .exportPackage(let record):
            library.deleteExportPackage(record)
        case .exportRecovery(let record):
            library.deleteExportRecovery(record)
        case .allTrajectories:
            library.deleteAllTrajectories()
        case .allRGBVideos:
            library.deleteAllRGBVideos()
        case .allCaptures:
            library.deleteAllCaptures()
        case .none:
            break
        }
        pendingDeletion = nil
    }

    private func trajectoryCard(
        _ record: TrajectoryCaptureRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(record.displayName)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(
                language.text(
                    "\(record.archive.pointCount) points · metre",
                    "\(record.archive.pointCount) 个点 · 米"
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Button {
                    trajectoryPreview = record
                } label: {
                    Label(
                        language.text(
                            "Play trajectory",
                            "播放轨迹"
                        ),
                        systemImage: "play.circle"
                    )
                }
                .buttonStyle(.borderless)

                ShareLink(item: record.fileURL) {
                    Label(
                        language.text("Send", "发送"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 5)
    }

    private func rgbCard(
        _ record: RGBCaptureRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.displayName)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()

            Text(
                [
                    record.info.lensMode?.shortLabel,
                    "\(record.info.width)×\(record.info.height)",
                    "\(record.info.nominalFPS) FPS",
                    language.text(
                        "encoded \(record.info.encodedFrameCount)",
                        "已编码 \(record.info.encodedFrameCount)"
                    ),
                    language.text(
                        "dropped \(record.info.droppedFrameCount)",
                        "已丢弃 \(record.info.droppedFrameCount)"
                    )
                ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 18) {
                Button {
                    rgbPreview = record
                } label: {
                    Label(
                        language.text("Play", "播放"),
                        systemImage: "play.rectangle"
                    )
                }
                .buttonStyle(.borderless)

                ShareLink(items: record.shareURLs) {
                    Label(
                        language.text("Send", "发送"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 5)
    }

    private func exportPackageCard(
        _ record: CaptureExportPackageRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.displayName)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(
                language.text(
                    "Verified completed package",
                    "已验证完成的导出包"
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            ShareLink(item: record.fileURL) {
                Label(
                    language.text("Send ZIP", "发送 ZIP"),
                    systemImage: "square.and.arrow.up"
                )
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 5)
    }

    private func recoveryCard(
        _ record: CaptureExportRecoveryRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(record.displayName, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(record.diagnostic)
                .font(.caption)
                .foregroundStyle(.orange)
            if !record.isDeletionEligible {
                Text(
                    language.text(
                        "Preserved; relaunch before manual management.",
                        "已保留；重新启动后才可手动管理。"
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

private enum CaptureDeletion {
    case trajectory(TrajectoryCaptureRecord)
    case rgbVideo(RGBCaptureRecord)
    case exportPackage(CaptureExportPackageRecord)
    case exportRecovery(CaptureExportRecoveryRecord)
    case allTrajectories
    case allRGBVideos
    case allCaptures

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .trajectory(let record):
            return language.text(
                "Delete trajectory \(record.displayName)?",
                "删除轨迹 \(record.displayName)？"
            )
        case .rgbVideo(let record):
            return language.text(
                "Delete RGB video \(record.displayName)?",
                "删除 RGB 视频 \(record.displayName)？"
            )
        case .exportPackage(let record):
            return language.text(
                "Delete export package \(record.displayName)?",
                "删除导出包 \(record.displayName)？"
            )
        case .exportRecovery(let record):
            return language.text(
                "Delete preserved file \(record.displayName)?",
                "删除保留文件 \(record.displayName)？"
            )
        case .allTrajectories:
            return language.text(
                "Delete all trajectories?",
                "删除全部轨迹？"
            )
        case .allRGBVideos:
            return language.text(
                "Delete all RGB videos?",
                "删除全部 RGB 视频？"
            )
        case .allCaptures:
            return language.text(
                "Delete all recent captures?",
                "删除全部最近采集？"
            )
        }
    }

    func buttonTitle(_ language: AppLanguage) -> String {
        switch self {
        case .trajectory:
            return language.text("Delete Trajectory", "删除轨迹")
        case .rgbVideo:
            return language.text("Delete RGB Video", "删除 RGB 视频")
        case .exportPackage:
            return language.text("Delete Export Package", "删除导出包")
        case .exportRecovery:
            return language.text("Delete Preserved File", "删除保留文件")
        case .allTrajectories:
            return language.text(
                "Delete All Trajectories",
                "删除全部轨迹"
            )
        case .allRGBVideos:
            return language.text(
                "Delete All RGB Videos",
                "删除全部 RGB 视频"
            )
        case .allCaptures:
            return language.text(
                "Delete Everything",
                "全部删除"
            )
        }
    }

    func message(_ language: AppLanguage) -> String {
        switch self {
        case .trajectory, .rgbVideo, .exportPackage:
            return language.text(
                "This permanently removes only the selected completed "
                    + "capture. There is no trash or undo.",
                "这只会永久删除当前选中的已完成采集，"
                    + "不会进入垃圾篓，也无法撤销。"
            )
        case .exportRecovery(let record):
            return language.text(
                "This permanently removes only the preserved incomplete "
                    + "or corrupt export artifact \(record.displayName). "
                    + "There is no trash or undo.",
                "这只会永久删除保留的不完整或损坏导出文件 "
                    + "\(record.displayName)，不会进入垃圾篓，也无法撤销。"
            )
        case .allTrajectories, .allRGBVideos, .allCaptures:
            return language.text(
                "This permanently removes the selected completed "
                    + "captures. There is no trash or undo.",
                "这会永久删除选中的已完成采集，"
                    + "不会进入垃圾篓，也无法撤销。"
            )
        }
    }
}

private struct ArchivedTrajectoryPreviewView: View {
    let record: TrajectoryCaptureRecord
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
            VStack(spacing: 12) {
                HStack {
                    Label(
                        language.text(
                            "\(record.archive.pointCount) points",
                            "\(record.archive.pointCount) 个点"
                        ),
                        systemImage: "point.3.filled.connected.trianglepath.dotted"
                    )
                    Spacer()
                    Text(displacementText)
                        .foregroundStyle(.orange)
                }
                .font(.subheadline.weight(.semibold))

                Text(record.displayName)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                TrajectoryPlot3D(
                    samples: record.visualizationSamples,
                    yaw: yaw,
                    pitch: pitch,
                    visibleSampleCount: visibleSampleCount,
                    playbackHeadSample: playbackHeadSample,
                    startLabel: language.text("START", "起点"),
                    endLabel: language.text("END", "终点")
                )
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .contentShape(Rectangle())
                .gesture(rotationGesture)
                .overlay(alignment: .bottomTrailing) {
                    Text(
                        language.text(
                            "Drag to rotate",
                            "拖动旋转"
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(10)
                }

                TrajectoryPlaybackControls(
                    samples: record.visualizationSamples,
                    language: language,
                    visibleSampleCount: $visibleSampleCount,
                    playbackHeadSample: $playbackHeadSample,
                    isPlaying: $isTrajectoryPlaying
                )

                HStack {
                    Label(
                        language.text("−X up", "−X 向上"),
                        systemImage: "circle.fill"
                    )
                        .foregroundStyle(.red)
                    Label("Y", systemImage: "circle.fill")
                        .foregroundStyle(.green)
                    Label("Z", systemImage: "circle.fill")
                        .foregroundStyle(.blue)
                    Spacer()
                    ShareLink(item: record.fileURL) {
                        Label(
                            language.text("Send JSON", "发送 JSON"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
                .font(.caption.weight(.semibold))
            }
            .padding()
            .navigationTitle(
                language.text(
                    "Trajectory Playback",
                    "轨迹回放"
                )
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

    private var displacementText: String {
        guard let last = record.visualizationSamples.last else {
            return "0.000 m"
        }
        return String(
            format: language.text(
                "%.3f m from origin",
                "距原点 %.3f 米"
            ),
            simd_length(last.position)
        )
    }

    private var rotationGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                yaw = dragStartYaw + value.translation.width * 0.01
                pitch = min(
                    1.2,
                    max(
                        -1.2,
                        dragStartPitch
                            - value.translation.height * 0.01
                    )
                )
            }
            .onEnded { _ in
                dragStartYaw = yaw
                dragStartPitch = pitch
            }
    }
}

private struct RGBLibraryVideoPreviewView: View {
    let record: RGBCaptureRecord
    let language: AppLanguage

    @State private var player: AVPlayer

    init(
        record: RGBCaptureRecord,
        language: AppLanguage
    ) {
        self.record = record
        self.language = language
        _player = State(
            initialValue: AVPlayer(url: record.videoURL)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .background(Color.black)

                Text(record.displayName)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .navigationTitle(
                language.text("RGB Capture", "RGB 录像")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(items: record.shareURLs) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(
                        language.text(
                            "Send RGB package",
                            "发送 RGB 数据包"
                        )
                    )
                }
            }
            .onAppear {
                player.seek(to: .zero)
                player.play()
            }
            .onDisappear {
                player.pause()
            }
        }
    }
}
