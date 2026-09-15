import Foundation
import SocketIO
import simd

enum SocketConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

struct RemoteCaptureCommand {
    let command: String
    let commandID: String
    let issuedAtUTC: String?
    let issuedUnixNs: String?
    let runID: String?
}

class SocketClient{
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var connectionHostIP: String?
    private var connectionHostPort: Int?
    private var connectionPairingToken: String?
    private var shouldMaintainConnection = false
    private var connectionGeneration = UUID()
    private var registrationAcknowledged = false
    private var pendingTerminalGroupRequest: GroupCaptureCommandName?
    private var pendingGroupResetRequestID: String?
    private var groupPreparationDelivery =
        GroupPreparationRequestDeliveryState()
    private var groupTransitionDelivery =
        GroupTransitionRequestDeliveryState()

    var onConnectionStateChange: ((SocketConnectionState) -> Void)?
    var onCaptureCommand: ((RemoteCaptureCommand) -> Void)?
    var onGroupCommand: ((GroupCaptureCommand) -> Void)?
    var onGroupState: (([String: Any]) -> Void)?
    var onClockSample: ((CaptureClockMappingSample) -> Void)?
    var onRegistrationAck: (([String: Any]) -> Void)?
    var onEgoPreviewFrame: (([String: Any]) -> Void)?
    var ready: Bool = false
    var socketOpened: Bool
    var prevTimestamp: Double = 0
    private var registrationPayload: [String: Any]?
    private var clockEstimator = CoordinatorClockEstimator()
    private var outstandingTimeProbes: [String: UInt64] = [:]
    private var clockRefreshGeneration = UUID()
    private var lastFrameClockAnchorSentLocalNs: UInt64 = 0
    init(){
        socketOpened = false
    }

    func connect(
        hostIP: String,
        hostPort: Int,
        pairingToken: String? = nil,
        registrationPayload: [String: Any]? = nil
    ) {
        self.registrationPayload = registrationPayload
        connectionHostIP = hostIP
        connectionHostPort = hostPort
        connectionPairingToken = pairingToken
        shouldMaintainConnection = true
        rebuildConnection()
    }

    private func rebuildConnection() {
        guard shouldMaintainConnection,
              let hostIP = connectionHostIP,
              let hostPort = connectionHostPort
        else { return }
        connectionGeneration = UUID()
        let generation = connectionGeneration
        registrationAcknowledged = false
        clockEstimator.reset()
        outstandingTimeProbes.removeAll()
        clockRefreshGeneration = UUID()
        manager?.disconnect()
        manager = nil
        socket = nil
        updateConnectionState(.connecting)
        guard let url = URL(
            string: "http://\(hostIP):\(hostPort)"
        ) else {
            manager = nil
            socket = nil
            updateConnectionState(.disconnected)
            return
        }
        self.manager = SocketManager(
            socketURL: url,
            config: [
                .log(false),
                .compress,
                // Capture coordination mutates the same UI-owned state as
                // ARSession callbacks. Keep every Socket.IO callback on the
                // main queue so Stop/finalization and the next Prepare cannot
                // overlap a frame-state mutation on another queue.
                .handleQueue(.main),
                .forceNew(true),
                .reconnects(true),
                .reconnectAttempts(-1),
                .reconnectWait(1),
                .reconnectWaitMax(5)
            ]
        )
        self.socket = self.manager?.defaultSocket
        registerConnectionHandlers(generation: generation)
        if let pairingToken = connectionPairingToken,
           !pairingToken.isEmpty {
            self.socket?.connect(withPayload: ["pairing_token": pairingToken])
        } else {
            self.socket?.connect()
        }
        scheduleConnectionRecovery(generation: generation)
    }

    func sendData(_ data: PosePacketV1) {
        guard ready else {
            return
        }
        prevTimestamp = data.timestamp
        self.socket?.emit("update", data.toBytes().base64EncodedString())
    }

    func sendCaptureControl(
        _ command: String,
        commandID: String? = nil
    ) {
        guard ready else {
            return
        }
        var payload = ["command": command]
        if let commandID {
            payload["command_id"] = commandID
        }
        socket?.emit("capture_control", payload)
    }

    func sendCaptureStatus(
        command: RemoteCaptureCommand,
        state: String,
        arFrameTimestamp: Double
    ) {
        guard ready else {
            return
        }

        var payload: [String: Any] = [
            "command": command.command,
            "command_id": command.commandID,
            "state": state,
            "device_uptime_ns": String(
                DispatchTime.now().uptimeNanoseconds
            ),
            "iphone_sent_unix_ns": String(
                Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            ),
            "ar_frame_timestamp_s": arFrameTimestamp
        ]
        if let issuedAtUTC = command.issuedAtUTC {
            payload["issued_at_utc"] = issuedAtUTC
        }
        if let issuedUnixNs = command.issuedUnixNs {
            payload["issued_unix_ns"] = issuedUnixNs
        }
        if let runID = command.runID {
            payload["run_id"] = runID
        }
        socket?.emit("capture_status", payload)
    }

    func sendTrajectoryDisplayFrame(
        xAxis: SIMD3<Float>,
        yAxis: SIMD3<Float>,
        zAxis: SIMD3<Float>,
        coordinateFrame: String = "x-forward_y-left_z-up",
        verticalAxis: String = "z",
        groundPlane: String = "x-y",
        physicalTCPProfileID: String? = nil
    ) {
        guard ready else {
            return
        }
        var payload: [String: Any] = [
            "x_axis": [xAxis.x, xAxis.y, xAxis.z],
            "y_axis": [yAxis.x, yAxis.y, yAxis.z],
            "z_axis": [zAxis.x, zAxis.y, zAxis.z],
            "coordinate_frame": coordinateFrame,
            "vertical_axis": verticalAxis,
            "ground_plane": groundPlane
        ]
        if let physicalTCPProfileID {
            payload["physical_tcp_profile_id"] = physicalTCPProfileID
        }
        socket?.emit("capture_display_frame", payload)
    }

    func sendGroupAcknowledgement(_ payload: [String: Any]) {
        guard ready else { return }
        socket?.emit(CaptureCoordinationProtocol.groupAck, payload)
    }

    func sendFrameClockAnchor(arkitTimestampSeconds: Double) {
        guard ready,
              arkitTimestampSeconds.isFinite,
              arkitTimestampSeconds >= 0
        else { return }
        let callbackLocalNs = DispatchTime.now().uptimeNanoseconds
        if lastFrameClockAnchorSentLocalNs > 0,
           callbackLocalNs - lastFrameClockAnchorSentLocalNs < 1_000_000_000 {
            return
        }
        guard let sample = clockEstimator.bestSample(
            nowLocalMonotonicNs: callbackLocalNs
        ) else { return }
        guard let frameLocalNs = CaptureFrameWindow.localMonotonicNs(
            arkitTimestampSeconds: arkitTimestampSeconds
        ) else { return }
        guard callbackLocalNs >= frameLocalNs,
              let coordinatorFrameNs = sample.coordinatorMonotonicNs(
                forLocal: frameLocalNs
              )
        else { return }
        lastFrameClockAnchorSentLocalNs = callbackLocalNs
        let deviceID = registrationPayload?["device_id"] as? String
        guard let deviceID else { return }
        socket?.emit(
            CaptureCoordinationProtocol.frameClockAnchor,
            [
                "protocol_version": CaptureCoordinationProtocol.version,
                "device_id": deviceID,
                "probe_id": sample.probeID,
                "arkit_timestamp_s": arkitTimestampSeconds,
                "frame_local_monotonic_ns": String(frameLocalNs),
                "callback_local_monotonic_ns": String(callbackLocalNs),
                "frame_callback_lag_ns": String(callbackLocalNs - frameLocalNs),
                "coordinator_frame_monotonic_ns": String(coordinatorFrameNs),
                "uncertainty_ns": String(sample.uncertaintyNs),
                "clock_sample_age_ns": String(
                    sample.ageNs(nowLocalMonotonicNs: callbackLocalNs)
                )
            ]
        )
    }

    func updateCoordinationRegistration(_ payload: [String: Any]) {
        registrationPayload = payload
        if ready {
            registerCoordinationIdentityIfAvailable()
        }
    }

    func sendGroupRequest(
        _ command: GroupCaptureCommandName,
        recoverPreviousSession: Bool = false,
        autoRearmAfterCapture: Bool = false
    ) {
        guard command != .pause && command != .resume else { return }
        if command == .stop {
            pendingTerminalGroupRequest = command
        } else if command == .prepare {
            guard let request = groupPreparationDelivery.begin(
                recoverPreviousSession: recoverPreviousSession,
                autoRearmAfterCapture: autoRearmAfterCapture,
                ready: ready,
                registrationAcknowledged: registrationAcknowledged
            ) else { return }
            emitGroupRequest(
                command,
                recoverPreviousSession: request.recoverPreviousSession,
                autoRearmAfterCapture: request.autoRearmAfterCapture,
                requestID: request.requestID
            )
            return
        } else {
            guard let request = groupTransitionDelivery.begin(
                command: command,
                ready: ready,
                registrationAcknowledged: registrationAcknowledged
            ) else {
                if ready {
                    registerCoordinationIdentityIfAvailable()
                }
                return
            }
            emitGroupRequest(
                request.command,
                requestID: request.requestID
            )
            return
        }
        guard ready, registrationAcknowledged else { return }
        emitGroupRequest(
            command,
            recoverPreviousSession: recoverPreviousSession
        )
    }

    func acknowledgeGroupRequest(_ command: GroupCaptureCommandName) {
        if pendingTerminalGroupRequest == command {
            pendingTerminalGroupRequest = nil
        }
    }

    func clearPendingTerminalGroupRequest() {
        pendingTerminalGroupRequest = nil
    }

    func clearPendingGroupPreparationRequest() {
        groupPreparationDelivery.clear()
    }

    func clearPendingGroupTransitionRequest() {
        groupTransitionDelivery.clear()
    }

    func sendGroupResetRequest() {
        let requestID = UUID().uuidString
        guard ready, registrationAcknowledged else {
            pendingGroupResetRequestID = requestID
            if ready {
                registerCoordinationIdentityIfAvailable()
            }
            return
        }
        pendingGroupResetRequestID = nil
        emitRawGroupRequest("reset", requestID: requestID)
    }

    func clearPendingGroupResetRequest() {
        pendingGroupResetRequestID = nil
    }

    private func emitGroupRequest(
        _ command: GroupCaptureCommandName,
        recoverPreviousSession: Bool = false,
        autoRearmAfterCapture: Bool = false,
        requestID: String? = nil
    ) {
        emitRawGroupRequest(
            command.rawValue,
            recoverPreviousSession: recoverPreviousSession,
            autoRearmAfterCapture: autoRearmAfterCapture,
            requestID: requestID
        )
    }

    private func emitRawGroupRequest(
        _ command: String,
        recoverPreviousSession: Bool = false,
        autoRearmAfterCapture: Bool = false,
        requestID: String? = nil
    ) {
        var payload: [String: Any] = [
            "protocol_version": CaptureCoordinationProtocol.version,
            "command": command,
            "recover_previous_session": recoverPreviousSession,
            "auto_rearm_after_capture": autoRearmAfterCapture
        ]
        if let requestID {
            payload["request_id"] = requestID
        }
        socket?.emit(CaptureCoordinationProtocol.groupRequest, payload)
    }

    func disconnect() {
        shouldMaintainConnection = false
        connectionGeneration = UUID()
        registrationAcknowledged = false
        clockRefreshGeneration = UUID()
        manager?.disconnect()
        manager = nil
        socket = nil
        updateConnectionState(.disconnected)
    }

    func ensureConnected() {
        guard shouldMaintainConnection, !ready else { return }
        rebuildConnection()
    }

    func sendEgoPreviewFrame(_ payload: [String: Any]) {
        guard ready else { return }
        socket?.emit(CaptureCoordinationProtocol.egoPreviewFrame, payload)
    }

    private func registerConnectionHandlers(generation: UUID) {
        socket?.on(clientEvent: .statusChange) { [weak self] data, _ in
            guard self?.connectionGeneration == generation else { return }
            guard let status = data.first as? SocketIOStatus else {
                return
            }

            switch status {
            case .connected:
                self?.updateConnectionState(.connected)
            case .connecting:
                self?.updateConnectionState(.connecting)
            case .disconnected, .notConnected:
                self?.registrationAcknowledged = false
                self?.updateConnectionState(.disconnected)
                self?.scheduleConnectionRecovery(generation: generation)
            }
        }

        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            self?.handleConnected(generation: generation)
        }

        socket?.on("capture_command") { [weak self] data, _ in
            guard
                let payload = data.first as? [String: Any],
                let command = payload["command"] as? String,
                let commandID = payload["command_id"] as? String
            else {
                return
            }

            let remoteCommand = RemoteCaptureCommand(
                command: command,
                commandID: commandID,
                issuedAtUTC: payload["issued_at_utc"] as? String,
                issuedUnixNs: payload["issued_unix_ns"] as? String,
                runID: payload["run_id"] as? String
            )
            self?.onCaptureCommand?(remoteCommand)
        }

        socket?.on(CaptureCoordinationProtocol.registerAck) { [weak self] data, _ in
            guard self?.connectionGeneration == generation else { return }
            guard let payload = data.first as? [String: Any] else { return }
            if payload["accepted"] as? Bool == true {
                self?.registrationAcknowledged = true
                if let command = self?.pendingTerminalGroupRequest {
                    self?.emitGroupRequest(command)
                }
                if let request = self?.groupPreparationDelivery
                    .takeAfterRegistrationAcknowledgement() {
                    self?.emitGroupRequest(
                        .prepare,
                        recoverPreviousSession: request.recoverPreviousSession,
                        autoRearmAfterCapture: request.autoRearmAfterCapture,
                        requestID: request.requestID
                    )
                }
                if let request = self?.groupTransitionDelivery
                    .takeAfterRegistrationAcknowledgement() {
                    self?.emitGroupRequest(
                        request.command,
                        requestID: request.requestID
                    )
                }
                if let requestID = self?.pendingGroupResetRequestID {
                    self?.pendingGroupResetRequestID = nil
                    self?.emitRawGroupRequest(
                        "reset",
                        requestID: requestID
                    )
                }
            }
            self?.onRegistrationAck?(payload)
        }

        socket?.on(CaptureCoordinationProtocol.groupCommand) { [weak self] data, _ in
            guard
                let payload = data.first as? [String: Any],
                let command = GroupCaptureCommand.decode(payload)
            else { return }
            if command.command == .prepare {
                self?.groupPreparationDelivery.clear()
            }
            self?.onGroupCommand?(command)
        }

        socket?.on(CaptureCoordinationProtocol.groupState) { [weak self] data, _ in
            guard let payload = data.first as? [String: Any] else { return }
            self?.onGroupState?(payload)
        }

        socket?.on(CaptureCoordinationProtocol.egoPreviewFrame) {
            [weak self] data, _ in
            guard self?.connectionGeneration == generation,
                  let payload = data.first as? [String: Any]
            else { return }
            self?.onEgoPreviewFrame?(payload)
        }


        socket?.on(CaptureCoordinationProtocol.timeReply) { [weak self] data, _ in
            guard self?.connectionGeneration == generation else { return }
            self?.acceptTimeReply(data.first as? [String: Any])
        }

        socket?.on(CaptureCoordinationProtocol.clockRefreshRequest) {
            [weak self] data, _ in
            guard let self,
                  self.connectionGeneration == generation,
                  let payload = data.first as? [String: Any],
                  payload["protocol_version"] as? Int
                    == CaptureCoordinationProtocol.version
            else { return }
            self.sendImmediateTimeProbeBurst(
                generation: self.clockRefreshGeneration
            )
        }
    }

    private func handleConnected(generation: UUID) {
        guard shouldMaintainConnection,
              connectionGeneration == generation
        else { return }
        registrationAcknowledged = false
        updateConnectionState(.connected)
        registerCoordinationIdentityIfAvailable()
        beginClockRefreshLoop()
        scheduleRegistrationRecovery(
            generation: generation,
            remainingRetries: 3
        )
    }

    private func scheduleRegistrationRecovery(
        generation: UUID,
        remainingRetries: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self,
                  self.shouldMaintainConnection,
                  self.connectionGeneration == generation,
                  self.ready,
                  !self.registrationAcknowledged
            else { return }
            if remainingRetries > 0 {
                self.registerCoordinationIdentityIfAvailable()
                self.scheduleRegistrationRecovery(
                    generation: generation,
                    remainingRetries: remainingRetries - 1
                )
            } else {
                self.rebuildConnection()
            }
        }
    }

    private func scheduleConnectionRecovery(generation: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self,
                  self.shouldMaintainConnection,
                  self.connectionGeneration == generation,
                  !self.ready
            else { return }
            self.rebuildConnection()
        }
    }

    private func registerCoordinationIdentityIfAvailable() {
        guard let registrationPayload else { return }
        socket?.emit(CaptureCoordinationProtocol.register, registrationPayload)
    }

    private func beginClockRefreshLoop() {
        let generation = UUID()
        clockRefreshGeneration = generation
        sendTimeProbe(generation: generation)
    }

    private func sendTimeProbe(generation: UUID) {
        guard clockRefreshGeneration == generation else { return }
        emitTimeProbeIfReady()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + CaptureCoordinationPolicy.clockRefreshInterval
        ) { [weak self] in
            self?.sendTimeProbe(generation: generation)
        }
    }

    private func sendImmediateTimeProbeBurst(generation: UUID) {
        for index in 0..<20 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(index) * 0.05
            ) { [weak self] in
                guard self?.clockRefreshGeneration == generation else { return }
                self?.emitTimeProbeIfReady()
            }
        }
    }

    private func emitTimeProbeIfReady() {
        guard ready else { return }
        let probeID = UUID().uuidString.lowercased()
        let localSend = DispatchTime.now().uptimeNanoseconds
        let retentionNs = CaptureCoordinationPolicy.maximumClockSampleAgeNs * 4
        outstandingTimeProbes = outstandingTimeProbes.filter {
            localSend >= $0.value && localSend - $0.value <= retentionNs
        }
        outstandingTimeProbes[probeID] = localSend
        socket?.emit(
            CaptureCoordinationProtocol.timeProbe,
            [
                "protocol_version": CaptureCoordinationProtocol.version,
                "probe_id": probeID,
                "local_send_monotonic_ns": String(localSend)
            ]
        )
    }

    private func acceptTimeReply(_ payload: [String: Any]?) {
        guard
            let payload,
            payload["protocol_version"] as? Int
                == CaptureCoordinationProtocol.version,
            let probeID = payload["probe_id"] as? String,
            let localSend = outstandingTimeProbes.removeValue(forKey: probeID),
            let echoedLocalSendText = payload["local_send_monotonic_ns"] as? String,
            UInt64(echoedLocalSendText) == localSend,
            let receiveText = payload["coordinator_receive_monotonic_ns"] as? String,
            let coordinatorReceive = UInt64(receiveText),
            let sendText = payload["coordinator_send_monotonic_ns"] as? String,
            let coordinatorSend = UInt64(sendText)
        else { return }
        let localReceive = DispatchTime.now().uptimeNanoseconds
        if let sample = clockEstimator.accept(
            probeID: probeID,
            localSendNs: localSend,
            localReceiveNs: localReceive,
            coordinatorReceiveNs: coordinatorReceive,
            coordinatorSendNs: coordinatorSend
        ) {
            onClockSample?(sample)
            if let deviceID = registrationPayload?["device_id"] as? String {
                socket?.emit(
                    CaptureCoordinationProtocol.clockSample,
                    [
                        "protocol_version": CaptureCoordinationProtocol.version,
                        "probe_id": sample.probeID,
                        "device_id": deviceID,
                        "local_midpoint_monotonic_ns": String(
                            sample.localMidpointMonotonicNs
                        ),
                        "coordinator_midpoint_monotonic_ns": String(
                            sample.coordinatorMidpointMonotonicNs
                        ),
                        "offset_ns": String(sample.offsetNs),
                        "rtt_ns": String(sample.rttNs),
                        "uncertainty_ns": String(sample.uncertaintyNs),
                        "sampled_at_local_monotonic_ns": String(
                            sample.sampledAtLocalMonotonicNs
                        )
                    ]
                )
            }
        }
    }

    private func updateConnectionState(_ state: SocketConnectionState) {
        ready = state == .connected
        socketOpened = state == .connected
        onConnectionStateChange?(state)
    }
}
