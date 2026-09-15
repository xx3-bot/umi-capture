import Combine
import Foundation
import Network

enum ReceiverDiscoveryState: Equatable {
    case idle
    case searching
    case noReceivers
    case networkUnavailable
    case localNetworkDenied
    case failed

    static func browserFailure(errorCode: Int) -> Self {
        // NSNetServicesMissingRequiredConfiguration (-72008) is also
        // reported when Local Network access is denied.
        errorCode == -72_008 ? .localNetworkDenied : .failed
    }
}

struct ReceiverResolutionRegistry {
    private var identitiesByServiceKey: [String: ObjectIdentifier] = [:]

    mutating func register(
        serviceKey: String,
        service: AnyObject
    ) {
        identitiesByServiceKey[serviceKey] = ObjectIdentifier(service)
    }

    mutating func remove(serviceKey: String) {
        identitiesByServiceKey.removeValue(forKey: serviceKey)
    }

    mutating func removeAll() {
        identitiesByServiceKey.removeAll()
    }

    func isCurrent(serviceKey: String, service: AnyObject) -> Bool {
        identitiesByServiceKey[serviceKey] == ObjectIdentifier(service)
    }
}

final class ReceiverDiscovery: NSObject, ObservableObject {
    @Published private(set) var endpoints: [ReceiverEndpoint] = []
    @Published private(set) var state: ReceiverDiscoveryState = .idle
    @Published private(set) var browserErrorCode: Int?

    private var browser: NetServiceBrowser?
    private var servicesByKey: [String: NetService] = [:]
    private var resolutionRegistry = ReceiverResolutionRegistry()
    private var endpointStore = ReceiverEndpointStore()
    private var pathMonitor: NWPathMonitor?
    private let pathQueue = DispatchQueue(
        label: "UMICapture.receiver-discovery.path"
    )
    private var noReceiversWorkItem: DispatchWorkItem?
    private var isRunning = false

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        beginBrowsing()

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkPath(path)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathQueue)
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        noReceiversWorkItem?.cancel()
        noReceiversWorkItem = nil
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        clearResolvedServices()
        browserErrorCode = nil
        state = .idle
    }

    func retry() {
        if isRunning {
            beginBrowsing()
        } else {
            start()
        }
    }

    private func beginBrowsing() {
        guard isRunning else {
            return
        }
        noReceiversWorkItem?.cancel()
        browser?.stop()
        browser?.delegate = nil
        clearResolvedServices()

        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browserErrorCode = nil
        state = .searching
        browser.searchForServices(
            ofType: ReceiverEndpoint.serviceType + ".",
            inDomain: "local."
        )
        scheduleNoReceiversState()
    }

    private func handleNetworkPath(_ path: NWPath) {
        guard isRunning else {
            return
        }
        if path.status != .satisfied {
            noReceiversWorkItem?.cancel()
            browser?.stop()
            clearResolvedServices()
            state = .networkUnavailable
        } else if state == .networkUnavailable {
            beginBrowsing()
        }
    }

    private func clearResolvedServices() {
        for service in servicesByKey.values {
            service.stop()
            service.delegate = nil
        }
        servicesByKey.removeAll()
        resolutionRegistry.removeAll()
        endpointStore.removeAll()
        endpoints = []
    }

    private func scheduleNoReceiversState() {
        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.isRunning,
                self.endpoints.isEmpty,
                self.state == .searching
            else {
                return
            }
            self.state = .noReceivers
        }
        noReceiversWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2,
            execute: workItem
        )
    }

    private func serviceKey(_ service: NetService) -> String {
        [service.domain, service.type, service.name].joined(
            separator: "|"
        )
    }

    private func publishEndpoints() {
        endpoints = endpointStore.endpoints
        if endpoints.isEmpty {
            if state != .networkUnavailable
                && state != .localNetworkDenied
                && state != .failed {
                state = .noReceivers
            }
        } else {
            noReceiversWorkItem?.cancel()
            state = .searching
        }
    }
}

extension ReceiverDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        state = .searching
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        let errorCode = errorDict[NetService.errorCode]?.intValue ?? 0
        browserErrorCode = errorCode
        state = .browserFailure(errorCode: errorCode)
        clearResolvedServices()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = serviceKey(service)
        if let previous = servicesByKey[key], previous !== service {
            previous.delegate = nil
            previous.stop()
        }
        servicesByKey[key] = service
        resolutionRegistry.register(serviceKey: key, service: service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let key = serviceKey(service)
        service.delegate = nil
        service.stop()
        guard
            let current = servicesByKey[key],
            current === service
        else {
            return
        }
        servicesByKey.removeValue(forKey: key)
        resolutionRegistry.remove(serviceKey: key)
        endpointStore.remove(serviceKey: key)
        publishEndpoints()
    }
}

extension ReceiverDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let key = serviceKey(sender)
        guard
            let current = servicesByKey[key],
            current === sender,
            resolutionRegistry.isCurrent(
                serviceKey: key,
                service: sender
            )
        else {
            return
        }
        guard
            let host = sender.hostName,
            let endpoint = ReceiverEndpoint.decode(
                txtRecord: sender.txtRecordData(),
                host: host,
                port: sender.port,
                serviceName: sender.name
            )
        else {
            endpointStore.remove(serviceKey: key)
            publishEndpoints()
            return
        }
        endpointStore.upsert(endpoint, serviceKey: key)
        publishEndpoints()
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let key = serviceKey(sender)
        guard
            let current = servicesByKey[key],
            current === sender,
            resolutionRegistry.isCurrent(
                serviceKey: key,
                service: sender
            )
        else {
            return
        }
        endpointStore.remove(serviceKey: key)
        publishEndpoints()
    }
}
