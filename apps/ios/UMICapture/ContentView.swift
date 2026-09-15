import SwiftUI

struct ContentView: View {
    @StateObject private var viewController = ViewController()
    @StateObject private var captureLibrary = CaptureLibrary.shared
    @StateObject private var receiverDiscovery = ReceiverDiscovery()
    @State private var showsTrajectory = false
    @State private var showsRecentCaptures = false
    @State private var showsSynchronizedSetup = false
    @State private var videoPreview: RGBVideoPreviewItem?
    @State private var captureShare: CaptureSharePresentation?
    @State private var pendingEndPreview: EndCapturePreview?
    @State private var exportWarning: String?
    @State private var pendingExportWarning: String?
    @State private var isEndingCapture = false
    @State private var isDrawerOpen = false
    @State private var receiverPairingToken = ""
    @GestureState private var egoPreviewDragTranslation: CGSize = .zero
    @AppStorage("UMICapture.egoPreview.portrait.x")
    private var egoPreviewPortraitX: Double = 0.5
    @AppStorage("UMICapture.egoPreview.portrait.y")
    private var egoPreviewPortraitY: Double = 0
    @AppStorage("UMICapture.egoPreview.landscape.x")
    private var egoPreviewLandscapeX: Double = 0
    @AppStorage("UMICapture.egoPreview.landscape.y")
    private var egoPreviewLandscapeY: Double = 1
    @AppStorage("UMICapture.language")
    private var language: AppLanguage = .simplifiedChinese
    @AppStorage("UMICapture.hostIP")
    private var newHostIP: String = "127.0.0.1"
    @AppStorage("UMICapture.hostPort")
    private var newHostPort: String = "5555"
    @AppStorage("UMICapture.preferredReceiverID")
    private var preferredReceiverID: String = ""

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                cameraSurface

                if viewController.shouldShowEgoPreview,
                   let image = viewController.egoPreviewImage {
                    let layoutClass = EgoPreviewLayoutPolicy.layoutClass(
                        for: geometry.size
                    )
                    let safeAreaInsets = egoPreviewSafeAreaInsets(
                        geometry.safeAreaInsets
                    )
                    let storedPosition = egoPreviewStoredPosition(
                        for: layoutClass
                    )
                    let baseCenter = EgoPreviewLayoutPolicy.center(
                        for: storedPosition,
                        containerSize: geometry.size,
                        safeAreaInsets: safeAreaInsets
                    )
                    let draggedCenter = EgoPreviewLayoutPolicy.clampedCenter(
                        CGPoint(
                            x: baseCenter.x + egoPreviewDragTranslation.width,
                            y: baseCenter.y + egoPreviewDragTranslation.height
                        ),
                        containerSize: geometry.size,
                        safeAreaInsets: safeAreaInsets
                    )
                    EgoPreviewThumbnailPanel(
                        image: image,
                        isStale: viewController.isEgoPreviewStale
                    )
                    .contentShape(Rectangle())
                    .position(draggedCenter)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .updating($egoPreviewDragTranslation) {
                                value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                let finalCenter =
                                    EgoPreviewLayoutPolicy.clampedCenter(
                                        CGPoint(
                                            x: baseCenter.x
                                                + value.translation.width,
                                            y: baseCenter.y
                                                + value.translation.height
                                        ),
                                        containerSize: geometry.size,
                                        safeAreaInsets: safeAreaInsets
                                    )
                                saveEgoPreviewPosition(
                                    EgoPreviewLayoutPolicy.normalizedPosition(
                                        for: finalCenter,
                                        containerSize: geometry.size,
                                        safeAreaInsets: safeAreaInsets
                                    ),
                                    for: layoutClass
                                )
                            }
                    )
                }

                if isDrawerOpen {
                    Color.black.opacity(0.38)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeDrawer()
                        }
                        .transition(.opacity)

                    CaptureDrawerView(
                        viewController: viewController,
                        library: captureLibrary,
                        receiverDiscovery: receiverDiscovery,
                        language: $language,
                        hostIP: $newHostIP,
                        hostPort: $newHostPort,
                        pairingToken: $receiverPairingToken,
                        preferredReceiverID: preferredReceiverID,
                        onClose: closeDrawer,
                        onShowTrajectory: {
                            closeDrawer()
                            showsTrajectory = true
                        },
                        onShowRecentCaptures: {
                            closeDrawer()
                            showsRecentCaptures = true
                        },
                        onSelectReceiver: selectReceiver,
                        onRetryDiscovery: receiverDiscovery.retry,
                        onConnect: connectReceiver
                    )
                    .frame(
                        width: min(geometry.size.width * 0.86, 390)
                    )
                    .transition(.move(edge: .leading))
                    .shadow(color: .black.opacity(0.3), radius: 18)
                    .gesture(drawerCloseGesture)
                } else {
                    Color.clear
                        .frame(width: 22)
                        .contentShape(Rectangle())
                        .gesture(edgeOpenGesture)
                }
            }
            .animation(
                .snappy(duration: 0.25),
                value: isDrawerOpen
            )
        }
            .onAppear {
                if !preferredReceiverID.isEmpty {
                    receiverPairingToken = ReceiverCredentialStore.token(
                        receiverID: preferredReceiverID
                    ) ?? ""
                }
                DispatchQueue.main.async {
                    receiverDiscovery.start()
                }
            }
            .onDisappear {
                DispatchQueue.main.async {
                    receiverDiscovery.stop()
                }
            }
            .onReceive(
                viewController.$synchronizedCaptureFallbackArtifacts
            ) { artifacts in
                guard let artifacts else { return }
                presentCompletedCapture(artifacts)
            }
            .onReceive(
                viewController.$completedStandaloneCaptureArtifacts
            ) { artifacts in
                guard let artifacts else { return }
                presentCompletedCapture(artifacts)
            }
            .sheet(isPresented: $showsTrajectory) {
                CurrentCaptureTrajectoryView(
                    viewController: viewController,
                    language: language
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $videoPreview) { item in
                RGBVideoPreviewView(
                    url: item.url,
                    shareURLs: item.shareURLs,
                    language: language
                )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsRecentCaptures) {
                RecentCapturesView(
                    library: captureLibrary,
                    language: language
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showsSynchronizedSetup) {
                SynchronizedCaptureSetupView(
                    viewController: viewController,
                    language: language
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(
                item: $captureShare,
                onDismiss: handleCaptureShareDismissed
            ) { item in
                CaptureActivityView(activityItems: item.urls)
                    .ignoresSafeArea()
            }
            .alert(
                language.text(
                    "Capture package warning",
                    "采集包提示"
                ),
                isPresented: Binding(
                    get: { exportWarning != nil },
                    set: {
                        if !$0 {
                            exportWarning = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    presentPendingEndPreview()
                }
            } message: {
                Text(exportWarning ?? "")
            }
    }

    private var cameraSurface: some View {
        ARViewContainer(viewController: viewController)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Button {
                    isDrawerOpen = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .accessibilityLabel(
                    language.text("Open menu", "打开菜单")
                )
                .accessibilityIdentifier("umi_capture.capture.drawer-button")
                .padding(.top, 52)
                .padding(.leading, 16)
            }
            .overlay(alignment: .topTrailing) {
                if let axes = viewController.axisDirections {
                    VIOAxesOverlay(axes: axes)
                        .padding(.top, 54)
                        .padding(.trailing, 16)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                captureControlsOverlay
            }
    }

    @ViewBuilder
    private var captureControlsOverlay: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 18) {
                    captureStatusPanel
                        .frame(
                            width: min(
                                330,
                                geometry.size.width * 0.40
                            )
                        )

                    Spacer(minLength: 12)

                    VStack(spacing: 10) {
                        homeCaptureControls
                        volumeKeyHint
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
                .padding(
                    .leading,
                    max(
                        geometry.safeAreaInsets.leading + 18,
                        76
                    )
                )
                .padding(
                    .trailing,
                    max(
                        geometry.safeAreaInsets.trailing + 18,
                        24
                    )
                )
                .padding(.vertical, 22)
            } else {
                VStack(spacing: 12) {
                    Spacer(minLength: 120)
                    captureStatusPanel
                        .frame(
                            maxWidth: .infinity,
                            alignment: .center
                        )
                    Spacer()
                    homeCaptureControls
                        .frame(
                            maxWidth: .infinity,
                            alignment: .center
                        )
                    volumeKeyHint
                        .frame(
                            maxWidth: .infinity,
                            alignment: .center
                        )
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
        }
    }

    private var volumeKeyHint: some View {
        Label(
            volumeKeyHintText,
            systemImage: "speaker.wave.2.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundColor(.white.opacity(0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.48))
        .clipShape(Capsule())
    }

    private var volumeKeyHintText: String {
        if viewController.isSynchronizedCaptureActive {
            return viewController.isSynchronizedCaptureController
                ? language.text(
                    "Either volume button  Start · End",
                    "任一音量键  同步开始 · 结束"
                )
                : language.text(
                    "Two-device mode · Either volume button Emergency End",
                    "双机协同中 · 任一音量键本机紧急结束"
                )
        }
        return language.text(
            "Either volume button  Start · End",
            "任一音量键  开始 · 结束"
        )
    }

    private var captureStatusPanel: some View {
        VStack(spacing: 10) {
            if let notice = viewController.captureUploadSuccessNotice {
                Label(
                    language.text(
                        "Uploaded to \(notice.destination): \(notice.filename)",
                        "已上传到 \(notice.destination)：\(notice.filename)"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption.weight(.bold))
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 380, alignment: .leading)
                .background(Color.green.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Text(
                language.localizedPoseDisplay(
                    viewController.displayString
                )
            )
            .font(.system(size: 18).monospaced())
            .multilineTextAlignment(.center)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(
                language.localizedRuntimeStatus(
                    viewController.calibrationStatus
                )
            )
            .font(
                .system(
                    size: 17,
                    weight: .semibold,
                    design: .rounded
                )
            )
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(statusColor.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Label(
                language.localizedStorageStatus(
                    viewController.storageStatusText
                ),
                systemImage: "internaldrive"
            )
            .font(.caption.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            captureLoadBar

            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                Text(connectionLabel)
                    .font(
                        .system(
                            size: 14,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
        }
        .animation(
            .snappy(duration: 0.25),
            value: viewController.captureUploadSuccessNotice
        )
    }

    private var captureLoadBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(captureLoadColor)
                    .frame(width: 8, height: 8)
                Text(
                    language.text(
                        "\(viewController.physicalMemoryMB) MB used · +\(viewController.safeGrowthBudgetMB) MB safe · \(viewController.thermalStateText)",
                        "已用 \(viewController.physicalMemoryMB) MB · 安全余量 +\(viewController.safeGrowthBudgetMB) MB · \(language.localizedThermalState(viewController.thermalStateText))"
                    )
                )
                .font(.caption2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            Text(
                language.localizedFinalizationStage(
                    viewController.captureFinalizationStage
                )
            )
                .font(.caption2.monospaced().weight(.bold))
                .textCase(.uppercase)
            ProgressView(
                value: Double(viewController.physicalMemoryMB),
                total: Double(
                    max(
                        1,
                        viewController.physicalMemoryMB
                            + viewController.availableMemoryMB
                    )
                )
            )
            .tint(captureLoadColor)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 380, alignment: .leading)
        .background(captureLoadColor.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var homeCaptureControls: some View {
        VStack(spacing: 10) {
            synchronizationStatusBar
            primaryControls
        }
    }

    private func egoPreviewSafeAreaInsets(
        _ insets: EdgeInsets
    ) -> EgoPreviewSafeAreaInsets {
        EgoPreviewSafeAreaInsets(
            top: insets.top,
            leading: insets.leading,
            bottom: insets.bottom,
            trailing: insets.trailing
        )
    }

    private func egoPreviewStoredPosition(
        for layoutClass: EgoPreviewLayoutClass
    ) -> EgoPreviewNormalizedPosition {
        switch layoutClass {
        case .portrait:
            return EgoPreviewNormalizedPosition(
                x: egoPreviewPortraitX,
                y: egoPreviewPortraitY
            )
        case .landscape:
            return EgoPreviewNormalizedPosition(
                x: egoPreviewLandscapeX,
                y: egoPreviewLandscapeY
            )
        }
    }

    private func saveEgoPreviewPosition(
        _ position: EgoPreviewNormalizedPosition,
        for layoutClass: EgoPreviewLayoutClass
    ) {
        switch layoutClass {
        case .portrait:
            egoPreviewPortraitX = position.x
            egoPreviewPortraitY = position.y
        case .landscape:
            egoPreviewLandscapeX = position.x
            egoPreviewLandscapeY = position.y
        }
    }

    private var synchronizationStatusBar: some View {
        Button {
            switch synchronizedPreparationButtonAction {
            case .prepare:
                viewController.persistCaptureIdentityFields()
                viewController.requestSynchronizedCapture()
            case .unavailable:
                break
            }
        } label: {
            HStack(spacing: 9) {
                Image(
                    systemName: synchronizedCaptureHasError
                        ? "exclamationmark.triangle.fill"
                        : (viewController.isSynchronizedCaptureActive
                            ? "link.circle.fill"
                            : "iphone.gen3")
                )
                Text(synchronizedCaptureButtonTitle)
                    .lineLimit(1)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(width: 340, height: 56)
            .background(synchronizationStatusColor.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .accessibilityHint(
            language.text(
                "Prepares or reconnects synchronized capture",
                "准备或重新连接同步采集"
            )
        )
        .accessibilityIdentifier("umi_capture.capture.home")
        .disabled(synchronizedPreparationButtonAction == .unavailable)
        .opacity(
            synchronizedPreparationButtonAction != .unavailable
                || viewController.isSynchronizedCaptureActive
                ? 1
                : 0.62
        )
    }

    private var synchronizedPreparationButtonAction:
        SynchronizedPreparationButtonAction {
        SynchronizedPreparationButtonPolicy.action(
            phase: viewController.synchronizedCapturePhase,
            isController: viewController.isSynchronizedCaptureController
        )
    }

    private var synchronizedCaptureButtonTitle: String {
        switch viewController.synchronizedCapturePhase {
        case .failed where viewController.synchronizedMembershipInterrupted:
            return language.text(
                "Two-device connection lost",
                "双机连接已中断"
            )
        case .failed:
            if viewController.groupCoordinationStatus
                .localizedCaseInsensitiveContains("clock") {
                return language.text(
                    "Start failed — clocks not synchronized",
                    "开始失败：设备时钟未同步"
                )
            }
            return language.text(
                "Two-device capture failed — prepare again",
                "双机采集失败，请重新准备"
            )
        case .inactive, .finalized:
            return language.text("Synchronized Capture", "同步采集")
        case .requesting:
            return language.text("Confirming two devices…", "正在确认双机…")
        case .preparing:
            return language.text("Two-device preparation", "双机准备中")
        case .armed:
            return language.text("Two devices armed", "双机已就绪")
        case .starting:
            return language.text("Synchronized Start…", "同步开始中…")
        case .running:
            return language.text("Two-device recording", "双机采集中")
        case .stopping, .finalizing:
            return language.text("Synchronized Stop…", "同步结束中…")
        }
    }

    private var synchronizationStatusColor: Color {
        if synchronizedCaptureHasError {
            return .red
        }
        return viewController.isSynchronizedCaptureActive ? .green : .blue
    }

    private var synchronizedCaptureHasError: Bool {
        viewController.synchronizedCapturePhase == .failed
    }

    private var primaryControls: some View {
        HStack(spacing: 14) {
            primaryButton(
                systemImage: primaryCaptureButtonImage,
                title: primaryCaptureButtonTitle,
                foreground: .primary,
                background: AnyShapeStyle(.regularMaterial),
                isDisabled: primaryCaptureButtonIsDisabled
            ) {
                viewController.performPrimaryCaptureSurfaceAction()
            }

            primaryButton(
                systemImage: isEndingCapture
                    ? "hourglass"
                    : "stop.fill",
                title: isEndingCapture
                    ? language.text("Saving", "保存中")
                    : language.text("End", "结束"),
                foreground: .white,
                background: AnyShapeStyle(Color.red.opacity(0.82)),
                isDisabled: endCaptureButtonIsDisabled
            ) {
                switch viewController.endCaptureSurfaceAction {
                case .group(let command):
                    viewController.requestGroupCommand(command)
                case .localEnd:
                    endCapture()
                case .localStart, .disabled:
                    break
                }
            }

            primaryButton(
                systemImage: "arrow.counterclockwise",
                title: language.text("Reset", "重置"),
                foreground: .primary,
                background: AnyShapeStyle(.regularMaterial),
                isDisabled: !viewController.canResetFromControlSurface
            ) {
                viewController.requestResetFromControlSurface()
            }
        }
    }

    private var primaryCaptureButtonImage: String {
        switch viewController.primaryCaptureSurfaceAction {
        case .group(.start), .localStart:
            return "play.fill"
        case .group, .localEnd, .disabled:
            return "play.fill"
        }
    }

    private var primaryCaptureButtonTitle: String {
        switch viewController.primaryCaptureSurfaceAction {
        case .group(.start), .localStart:
            return language.text("Start", "开始")
        case .group, .localEnd, .disabled:
            return language.text("Waiting", "等待")
        }
    }

    private var primaryCaptureButtonIsDisabled: Bool {
        switch viewController.primaryCaptureSurfaceAction {
        case .localStart, .group(.start):
            return primaryCaptureActionIsActive
                || viewController.hasLogicalCapture
                || !viewController.captureStartPrerequisitesMet
        case .group:
            return true
        case .localEnd, .disabled:
            return true
        }
    }

    private var endCaptureButtonIsDisabled: Bool {
        switch viewController.endCaptureSurfaceAction {
        case .localEnd:
            return isEndingCapture
                || viewController.rgbRecorderStatus.phase == .finishing
                || (!viewController.hasLogicalCapture
                    && !primaryCaptureActionIsActive)
        case .group(.stop):
            return false
        case .group, .localStart, .disabled:
            return true
        }
    }

    private var primaryCaptureActionIsActive: Bool {
        viewController.isStreaming
            || viewController.isCalibrating
            || viewController.isStarting
    }

    private func primaryButton(
        systemImage: String,
        title: String,
        foreground: Color,
        background: AnyShapeStyle,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 29, height: 29)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(foreground)
            .frame(width: 74, height: 70)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 17))
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.62 : 1)
    }

    private func endCapture() {
        guard !isEndingCapture else {
            return
        }
        isEndingCapture = true
        viewController.endCurrentCapture { artifacts in
            isEndingCapture = false
            presentCompletedCapture(artifacts)
        }
    }

    private func presentCompletedCapture(
        _ artifacts: CompletedCaptureArtifacts
    ) {
        if let videoURL = artifacts.primaryVideoURL {
            pendingEndPreview = .video(
                RGBVideoPreviewItem(
                    url: videoURL,
                    shareURLs: artifacts.shareURLs
                )
            )
        } else {
            pendingEndPreview = .trajectory
        }

        let shareURLs = artifacts.shareURLs
        if !shareURLs.isEmpty {
            viewController.prepareVIOForCaptureShare()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                captureShare = CaptureSharePresentation(urls: shareURLs)
            }
        } else {
            presentPendingEndPreview()
        }
        if artifacts.exportPackageURL != nil {
            pendingExportWarning = nil
            exportWarning = nil
        } else if let error = artifacts.exportError {
            pendingExportWarning = language.text(
                "The single ZIP could not be prepared. The available raw files were opened in the share sheet instead. \(error)",
                "单个 ZIP 采集包未能生成，已改为在分享界面中提供现有原始文件。\(error)"
            )
        }
    }

    private func handleCaptureShareDismissed() {
        viewController.restoreVIOAfterCaptureShare()
        if let pendingExportWarning {
            self.pendingExportWarning = nil
            exportWarning = pendingExportWarning
        } else {
            presentPendingEndPreview()
        }
    }

    private func presentPendingEndPreview() {
        guard let pendingEndPreview else {
            return
        }
        self.pendingEndPreview = nil
        switch pendingEndPreview {
        case .video(let item):
            videoPreview = item
        case .trajectory:
            showsTrajectory = true
        }
    }

    private func connectReceiver() {
        guard let port = Int(newHostPort) else {
            return
        }
        connectReceiver(
            target: ReceiverConnectionTarget(
                host: newHostIP,
                port: port
            )
        )
    }

    private func selectReceiver(_ endpoint: ReceiverEndpoint) {
        preferredReceiverID = endpoint.id
        newHostIP = endpoint.host
        newHostPort = String(endpoint.port)
        let decision = ReceiverSelectionCredentialDecision.resolve(
            userEnteredToken: receiverPairingToken,
            storedToken: ReceiverCredentialStore.token(
                receiverID: endpoint.id
            )
        )
        receiverPairingToken = decision.token
        connectReceiver(target: endpoint.connectionTarget)
    }

    private func connectReceiver(target: ReceiverConnectionTarget) {
        let credentialID = preferredReceiverID.isEmpty
            ? "manual-\(target.host)-\(target.port)"
            : preferredReceiverID
        viewController.configureReceiverCredential(
            receiverID: credentialID,
            pairingToken: receiverPairingToken.isEmpty
                ? nil
                : receiverPairingToken,
            receiverDisplayName: target.displayName
        )
        CaptureActionBus.shared.send(
            .update(ip: target.host, port: target.port)
        )
    }

    private func closeDrawer() {
        isDrawerOpen = false
    }

    private var edgeOpenGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                if value.translation.width > 55 {
                    isDrawerOpen = true
                }
            }
    }

    private var drawerCloseGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                if value.translation.width < -55 {
                    closeDrawer()
                }
            }
    }

    private var statusColor: Color {
        if viewController.isStreaming {
            return .green
        }
        if viewController.isStarting {
            return .blue
        }
        if viewController.isCalibrationReady {
            return .blue
        }
        return .orange
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

    private var connectionColor: Color {
        switch viewController.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        }
    }

    private var connectionLabel: String {
        switch viewController.connectionState {
        case .connected:
            return language.text("Connected", "已连接")
        case .connecting:
            return language.text("Connecting", "连接中")
        case .disconnected:
            return language.text("Disconnected", "未连接")
        }
    }
}

private struct SynchronizedCaptureSetupView: View {
    @ObservedObject var viewController: ViewController
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        language.text("Capture role", "采集角色"),
                        selection: Binding(
                            get: { viewController.captureProfileID },
                            set: { viewController.requestCaptureProfile($0) }
                        )
                    ) {
                        ForEach(
                            [CaptureProfileID.handheldUMI, .chestEGO]
                        ) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!viewController.canChangeCaptureProfile)

                    if viewController.captureProfileID == .handheldUMI {
                        TextField(
                            "gripper_id (required for bundled default)",
                            text: $viewController.gripperID
                        )
                        .textInputAutocapitalization(.never)
                        .disabled(!viewController.canChangeCaptureProfile)

                        TextField(
                            "camera_T_tcp calibration ID (required for bundled default)",
                            text: $viewController.calibrationID
                        )
                        .textInputAutocapitalization(.never)
                        .disabled(!viewController.canChangeCaptureProfile)

                        Button {
                            applyBundledFastUMIDefault()
                        } label: {
                            Label(
                                language.text(
                                    "Use bundled FastUMI × iPhUMI default",
                                    "使用内置 FastUMI × iPhUMI 默认配置"
                                ),
                                systemImage: "shippingbox.fill"
                            )
                        }
                        .disabled(!viewController.canChangeCaptureProfile)

                        Text(
                            language.text(
                                "Only use this default with the validated iPhone 15 Pro, official iPhUMI iPhone 15 Pro mount/top cover, and FastUMI mechanism. Other hardware requires its own validated configuration and IDs.",
                                "此默认配置仅适用于已验证的 iPhone 15 Pro、官方 iPhUMI iPhone 15 Pro 安装件/上盖与 FastUMI 机构。其他硬件必须使用各自经过验证的配置和 ID。"
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        TextField(
                            "camera_T_body calibration ID (optional)",
                            text: $viewController.calibrationID
                        )
                        .textInputAutocapitalization(.never)
                        .disabled(!viewController.canChangeCaptureProfile)
                    }
                } header: {
                    Text(language.text("Two-device roles", "双机角色"))
                } footer: {
                    Text(
                        language.text(
                            "Assign one phone to each role. Roles affect the capture stream and motion checks only while configuring synchronized capture.",
                            "两台手机须各选一个角色。角色仅在配置同步采集时用于选择数据流与运动检查策略。"
                        )
                    )
                }

                Section(language.text("Status", "状态")) {
                    Label(
                        synchronizedStatusText,
                        systemImage: viewController.connectionState == .connected
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(
                        viewController.connectionState == .connected
                            ? Color.green
                            : Color.orange
                    )

                    Text(viewController.groupCoordinationStatus)
                        .font(.caption)
                        .foregroundStyle(
                            viewController.synchronizedCapturePhase == .failed
                                ? Color.red
                                : Color.secondary
                        )

                    Text(
                        language.text(
                            "The two phones share timing, capture boundaries, and the same gravity-up / initial-camera-forward frame direction. Their positions remain in independent local ARKit worlds.",
                            "两台手机共享时间、采集边界以及“重力向上／初始相机向前”的同一 frame 方向；位置仍保留在各自独立的本地 ARKit 世界中。"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        viewController.persistCaptureIdentityFields()
                        viewController.requestSynchronizedCapture()
                        dismiss()
                    } label: {
                        Label(
                            language.text(
                                "Prepare synchronized capture",
                                "准备同步采集"
                            ),
                            systemImage: "iphone.gen3.radiowaves.left.and.right"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!canPrepare)

                    Button(role: .destructive) {
                        viewController.leaveSynchronizedMode()
                        dismiss()
                    } label: {
                        Label(
                            language.text(
                                "Leave synchronized mode",
                                "退出同步模式"
                            ),
                            systemImage: "rectangle.portrait.and.arrow.right"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(
                        !viewController.canResetWithoutDiscardingCapture
                            || !canLeaveSynchronizedMode
                    )
                }
            }
            .navigationTitle(
                language.text("Synchronized Capture", "同步采集")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(language.text("Done", "完成")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var canPrepare: Bool {
        SynchronizedPreparationButtonPolicy.action(
            phase: viewController.synchronizedCapturePhase,
            isController: viewController.isSynchronizedCaptureController
        ) == .prepare
            && viewController.canRequestSynchronizedCapture
    }

    private func applyBundledFastUMIDefault() {
        guard let preset = BundledFastUMIHardwareBinding.preset(
            for: viewController.captureProfileID
        ) else { return }
        viewController.gripperID = preset.gripperID
        viewController.calibrationID = preset.calibrationID
        viewController.persistCaptureIdentityFields()
    }

    private var canLeaveSynchronizedMode: Bool {
        viewController.synchronizedCapturePhase != .inactive
    }

    private var synchronizedStatusText: String {
        switch viewController.connectionState {
        case .connected:
            return language.text("Mac receiver connected", "Mac 接收端已连接")
        case .connecting:
            return language.text("Connecting to receiver", "正在连接接收端")
        case .disconnected:
            return language.text(
                "Connect the Mac receiver from the menu first",
                "请先从菜单连接 Mac 接收端"
            )
        }
    }
}

private struct EgoPreviewThumbnailPanel: View {
    let image: UIImage
    let isStale: (UInt64) -> Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let stale = isStale(
                DispatchTime.now().uptimeNanoseconds
            )
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 176, height: 132)
                    .background(Color.black)

                Text(stale ? "EGO · STALE" : "EGO · LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        (stale ? Color.red : Color.green)
                            .opacity(0.88)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
            .frame(width: 176, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        stale ? Color.red : Color.white.opacity(0.78),
                        lineWidth: 2
                    )
            }
            .shadow(color: .black.opacity(0.42), radius: 6, y: 2)
        }
    }
}

private struct RGBVideoPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
    let shareURLs: [URL]
}

private enum EndCapturePreview {
    case video(RGBVideoPreviewItem)
    case trajectory
}

private struct CaptureSharePresentation: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
