import SwiftUI

struct CaptureDrawerView: View {
    @ObservedObject var viewController: ViewController
    @ObservedObject var library: CaptureLibrary
    @ObservedObject var receiverDiscovery: ReceiverDiscovery

    @Binding var language: AppLanguage
    @Binding var hostIP: String
    @Binding var hostPort: String
    @Binding var pairingToken: String
    let preferredReceiverID: String

    let onClose: () -> Void
    let onShowTrajectory: () -> Void
    let onShowRecentCaptures: () -> Void
    let onSelectReceiver: (ReceiverEndpoint) -> Void
    let onRetryDiscovery: () -> Void
    let onConnect: () -> Void

    @State private var showsTutorial = false
    @State private var showsAbout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    languageSection
                    synchronizationRoleSection
                    navigationSection
                    rgbSection
                    networkSection
                    helpSection
                    hardwareHint
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("UMI Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(
                        language.text("Close menu", "关闭菜单")
                    )
                    .accessibilityIdentifier("umi_capture.capture.drawer")
                }
            }
            .sheet(isPresented: $showsTutorial) {
                UMICaptureTutorialView(language: language) {
                    showsTutorial = false
                }
            }
            .sheet(isPresented: $showsAbout) {
                UMICaptureAboutView(language: language)
            }
        }
    }

    private var languageSection: some View {
        drawerSection(title: language.text("LANGUAGE", "语言")) {
            Picker(
                language.text("Language", "语言"),
                selection: $language
            ) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.pickerLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("umi_capture.capture.language-picker")
        }
    }

    private var navigationSection: some View {
        drawerSection(
            title: language.text("DATA & PREVIEW", "数据与预览")
        ) {
            VStack(spacing: 10) {
                drawerButton(
                    title: language.text(
                        "Current Trajectory",
                        "当前轨迹"
                    ),
                    subtitle: language.text(
                        "\(viewController.trajectorySamples.count) points",
                        "\(viewController.trajectorySamples.count) 个点"
                    ),
                    systemImage: "move.3d",
                    action: onShowTrajectory
                )

                drawerButton(
                    title: language.text(
                        "Recent Captures",
                        "最近采集"
                    ),
                    subtitle: language.text(
                        "\(library.trajectories.count) trajectories · "
                            + "\(library.rgbVideos.count) RGB",
                        "\(library.trajectories.count) 条轨迹 · "
                            + "\(library.rgbVideos.count) 段 RGB"
                    ),
                    systemImage: "clock.arrow.circlepath",
                    accessibilityIdentifier:
                        "umi_capture.capture.recent-captures-button",
                    action: onShowRecentCaptures
                )
            }
        }
    }

    private var synchronizationRoleSection: some View {
        drawerSection(
            title: language.text(
                "SYNCHRONIZED CAPTURE",
                "同步采集"
            )
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    language.text("This phone's role", "本机角色"),
                    selection: Binding(
                        get: { viewController.captureProfileID },
                        set: { viewController.requestCaptureProfile($0) }
                    )
                ) {
                    Text("Hand").tag(CaptureProfileID.handheldUMI)
                    Text("Ego").tag(CaptureProfileID.chestEGO)
                }
                .pickerStyle(.segmented)
                .disabled(!viewController.canChangeCaptureProfile)

                Text(
                    language.text(
                        "The role is saved on this phone. Use the main synchronized-capture button to prepare or reconnect.",
                        "角色会保存在本机。准备或重新连接时，直接点击主界面的同步采集按钮。"
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                Toggle(
                    language.text(
                        "Automatically prepare the next capture (up to 5 delivery attempts)",
                        "完成后自动准备下一次采集（最多发送 5 次）"
                    ),
                    isOn: $viewController.autoRearmAfterCapture
                )

                Text(viewController.groupCoordinationStatus)
                    .font(.caption2.monospaced())
                    .accessibilityIdentifier("umi_capture.capture.role-setup")
                    .foregroundStyle(
                        viewController.synchronizedCapturePhase == .failed
                            ? Color.red
                            : Color.secondary
                    )
            }
        }
    }

    private var rgbSection: some View {
        drawerSection(
            title: language.text("CAPTURE & STORAGE", "采集与存储")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(
                    language.text(
                        "Record RGB video (default on)",
                        "录制 RGB 视频（默认开启）"
                    ),
                    isOn: $viewController.rgbRecordingEnabled
                )
                .disabled(!viewController.canChangeRGBRecordingSettings)

                if viewController.availableRGBCameraModes.count > 1 {
                    Picker(
                        language.text("Physical lens", "物理镜头"),
                        selection: Binding(
                            get: { viewController.rgbCameraMode },
                            set: { viewController.requestRGBCameraMode($0) }
                        )
                    ) {
                        ForEach(viewController.availableRGBCameraModes) { mode in
                            Text(mode.shortLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!viewController.canSwitchRGBCamera)
                }

                Picker(
                    language.text("Video frame rate", "视频帧率"),
                    selection: Binding(
                        get: { viewController.rgbRecordingFrameRate },
                        set: {
                            viewController.requestRGBRecordingFrameRate($0)
                        }
                    )
                ) {
                    ForEach(RGBRecordingFrameRate.allCases) { frameRate in
                        Text(frameRate.displayLabel).tag(frameRate)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!viewController.canChangeRGBRecordingSettings)

                Picker(
                    language.text("Video quality", "视频画质"),
                    selection: Binding(
                        get: { viewController.rgbRecordingQuality },
                        set: { viewController.requestRGBRecordingQuality($0) }
                    )
                ) {
                    Text(language.text("Compact", "省空间"))
                        .tag(RGBRecordingQuality.compact)
                    Text(language.text("Balanced", "均衡"))
                        .tag(RGBRecordingQuality.balanced)
                    Text(language.text("High", "高画质"))
                        .tag(RGBRecordingQuality.high)
                }
                .pickerStyle(.segmented)
                .disabled(!viewController.canChangeRGBRecordingSettings)

                Divider()

                captureStreamToggle(
                    title: language.text(
                        "Original main-camera RGB",
                        "主相机原始 RGB"
                    ),
                    isOn: Binding(
                        get: {
                            viewController.captureExportSelection
                                .includeRawRGBVideo
                        },
                        set: {
                            viewController.captureExportSelection
                                .includeRawRGBVideo = $0
                        }
                    )
                )
                captureStreamToggle(
                    title: language.text(
                        "Processed 224×224 RGB",
                        "处理后 224×224 RGB"
                    ),
                    isOn: Binding(
                        get: {
                            viewController.captureExportSelection
                                .includeProcessedRGBVideo
                        },
                        set: {
                            viewController.captureExportSelection
                                .includeProcessedRGBVideo = $0
                        }
                    )
                )
                captureStreamToggle(
                    title: language.text(
                        "Handheld UMI 0.5× observation",
                        "Handheld UMI 0.5× 观察流"
                    ),
                    isOn: Binding(
                        get: {
                            viewController.captureExportSelection
                                .includeUltrawideObservation
                        },
                        set: {
                            viewController.captureExportSelection
                                .includeUltrawideObservation = $0
                        }
                    )
                )

                Label(
                    language.localizedStorageStatus(
                        viewController.storageStatusText
                    ),
                    systemImage: "internaldrive"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 7) {
                    Circle()
                        .fill(captureLoadColor)
                        .frame(width: 8, height: 8)
                    Text(
                        language.text(
                            "\(viewController.physicalMemoryMB) MB used · +\(viewController.safeGrowthBudgetMB) MB safe · peak \(viewController.peakPhysicalMemoryMB) MB · \(viewController.thermalStateText)",
                            "已用 \(viewController.physicalMemoryMB) MB · 安全余量 +\(viewController.safeGrowthBudgetMB) MB · 峰值 \(viewController.peakPhysicalMemoryMB) MB · \(language.localizedThermalState(viewController.thermalStateText))"
                        )
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ultrawideObservationStatus

                if let error = viewController.rgbVideoFormatError
                    ?? viewController.rgbRecorderStatus.errorMessage {
                    Text(language.localizedCameraDiagnostic(error))
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var captureLoadColor: Color {
        switch viewController.captureLoadLevel {
        case .normal:
            return .green
        case .elevated:
            return .yellow
        case .high:
            return .orange
        case .critical:
            return .red
        }
    }

    private func captureStreamToggle(
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(title, isOn: isOn)
            .font(.subheadline)
            .disabled(!viewController.canChangeRGBRecordingSettings)
    }

    @ViewBuilder
    private var ultrawideObservationStatus: some View {
        switch viewController.ultrawideObservationStatus {
        case .checking:
            Label(
                language.text(
                    "Checking the native 0.5× observation path",
                    "正在检查原生 0.5× 观察链路"
                ),
                systemImage: "camera.metering.center.weighted"
            )
            .foregroundStyle(.secondary)
        case .privateAPIUnavailable:
            Label(
                language.text(
                    "0.5× observation unavailable on this iOS build",
                    "当前 iOS 版本无法读取 0.5× 观察流"
                ),
                systemImage: "camera.badge.ellipsis"
            )
            .foregroundStyle(.orange)
        case .waitingForMetricPose(let width, let height):
            Label(
                language.text(
                    "0.5× frame \(width)×\(height); waiting for pose",
                    "已检测 0.5× 画面 \(width)×\(height)，等待位姿"
                ),
                systemImage: "camera.fill"
            )
            .foregroundStyle(.blue)
        case .invalid:
            Label(
                language.text(
                    "0.5× observation validation failed",
                    "0.5× 观察流校验失败"
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        case .available(let metrics):
            Label(
                language.text(
                    "0.5× available · \(metrics.width)×\(metrics.height)",
                    "0.5× 可用 · \(metrics.width)×\(metrics.height)"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        }
    }

    private var networkSection: some View {
        drawerSection(title: language.text("RECEIVER", "接收端")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionStateColor)
                        .frame(width: 9, height: 9)
                    Text(connectionStateLabel)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(discoveryStateLabel)
                        .font(.caption2)
                        .foregroundStyle(discoveryStateColor)
                }

                if let guidance = discoveryGuidance {
                    Text(guidance)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onRetryDiscovery) {
                        Label(
                            language.text(
                                "Retry discovery",
                                "重新发现"
                            ),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                }

                ForEach(receiverDiscovery.endpoints) { endpoint in
                    Button {
                        onSelectReceiver(endpoint)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "desktopcomputer")
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(endpoint.displayName)
                                        .font(.subheadline.weight(.semibold))
                                    if isPreferred(endpoint) {
                                        Text(
                                            language.text(
                                                "Preferred",
                                                "常用"
                                            )
                                        )
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.blue)
                                    }
                                }
                                Text("\(endpoint.host):\(endpoint.port)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(language.text("Connect", "连接"))
                                .font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                Text(
                    language.text(
                        "Manual address fallback",
                        "手动地址备用"
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                TextField("Host IP", text: $hostIP)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)

                SecureField(
                    language.text(
                        "Laboratory pairing token (optional)",
                        "实验室配对令牌（可选）"
                    ),
                    text: $pairingToken
                )
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)

                HStack {
                    TextField(
                        language.text("Port", "端口"),
                        text: $hostPort
                    )
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)

                    Button(action: onConnect) {
                        Label(
                            language.text("Connect", "连接"),
                            systemImage: "network"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(Int(hostPort) == nil)
                }
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityIdentifier("umi_capture.capture.receiver-settings")
    }

    private var helpSection: some View {
        drawerSection(title: language.text("HELP", "帮助")) {
            VStack(spacing: 10) {
                drawerButton(
                    title: language.text("Tutorial", "使用教程"),
                    subtitle: language.text(
                        "Permissions, capture, storage, and export",
                        "权限、采集、存储与导出"
                    ),
                    systemImage: "book",
                    action: { showsTutorial = true }
                )
                drawerButton(
                    title: language.text(
                        "About UMI Capture",
                        "关于 UMI Capture"
                    ),
                    subtitle: language.text(
                        "Version, source, attribution, and feedback",
                        "版本、来源、署名与反馈"
                    ),
                    systemImage: "info.circle",
                    accessibilityIdentifier: "umi_capture.capture.about-button",
                    action: { showsAbout = true }
                )
            }
        }
    }

    private var connectionStateLabel: String {
        switch viewController.connectionState {
        case .connected:
            return language.text("Connected", "已连接")
        case .connecting:
            return language.text("Connecting", "连接中")
        case .disconnected:
            return language.text("Disconnected", "未连接")
        }
    }

    private var connectionStateColor: Color {
        switch viewController.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        }
    }

    private var discoveryStateLabel: String {
        switch receiverDiscovery.state {
        case .idle:
            return language.text("Discovery idle", "发现未启动")
        case .searching:
            return receiverDiscovery.endpoints.isEmpty
                ? language.text("Searching…", "正在搜索…")
                : language.text(
                    "\(receiverDiscovery.endpoints.count) found",
                    "发现 \(receiverDiscovery.endpoints.count) 台"
                )
        case .noReceivers:
            return language.text("No receiver found", "未发现接收端")
        case .networkUnavailable:
            return language.text("Network unavailable", "网络不可用")
        case .localNetworkDenied:
            return language.text(
                "Local Network access denied",
                "本地网络权限被拒绝"
            )
        case .failed:
            return language.text("Discovery failed", "发现失败")
        }
    }

    private var discoveryStateColor: Color {
        switch receiverDiscovery.state {
        case .localNetworkDenied, .networkUnavailable, .failed:
            return .orange
        default:
            return .secondary
        }
    }

    private var discoveryGuidance: String? {
        switch receiverDiscovery.state {
        case .noReceivers:
            return language.text(
                "Start the Mac receiver, confirm both devices use the same Wi-Fi, then retry or enter its IP below.",
                "请启动 Mac 接收端，确认设备位于同一 Wi-Fi，再重试或在下方输入 IP。"
            )
        case .networkUnavailable:
            return language.text(
                "Join Wi-Fi, then retry discovery.",
                "请先连接 Wi-Fi，再重新发现。"
            )
        case .localNetworkDenied:
            return language.text(
                "Enable Local Network for UMI Capture in iOS Settings, then retry.",
                "请在 iOS 设置中允许 UMI Capture 使用本地网络，再返回重试。"
            )
        case .failed:
            let suffix = receiverDiscovery.browserErrorCode.map {
                " (Bonjour \($0))"
            } ?? ""
            return language.text(
                "Bonjour discovery failed\(suffix). Retry or enter the IP below.",
                "Bonjour 发现失败\(suffix)。请重试或在下方输入 IP。"
            )
        case .idle, .searching:
            return nil
        }
    }

    private func isPreferred(_ endpoint: ReceiverEndpoint) -> Bool {
        !preferredReceiverID.isEmpty
            && endpoint.id.caseInsensitiveCompare(
                preferredReceiverID
            ) == .orderedSame
    }

    private var hardwareHint: some View {
        Label(
            language.text(
                "Either volume button controls Start and End",
                "任一音量键可控制开始与结束"
            ),
            systemImage: "speaker.wave.2.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func drawerSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func drawerButton(
        title: String,
        subtitle: String,
        systemImage: String,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }
}
