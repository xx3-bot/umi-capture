import Foundation
import XCTest
@testable import UMICapture

final class ReceiverDiscoveryTests: XCTestCase {
    private let stableID = UUID(
        uuidString: "11111111-1111-4111-8111-111111111111"
    )!

    func testExactBonjourContractDecodesEndpoint() throws {
        let endpoint = try XCTUnwrap(
            ReceiverEndpoint.decode(
                txtRecord: txtRecord(
                    id: stableID.uuidString,
                    name: "Lab Mac",
                    version: "1"
                ),
                host: "lab-mac.local.",
                port: 5555,
                serviceName: "UMI Capture Receiver"
            )
        )

        XCTAssertEqual(ReceiverEndpoint.serviceType, "_umicapture._tcp")
        XCTAssertEqual(endpoint.stableID, stableID)
        XCTAssertEqual(endpoint.displayName, "Lab Mac")
        XCTAssertEqual(endpoint.host, "lab-mac.local")
        XCTAssertEqual(endpoint.port, 5555)
    }

    func testInvalidIdentityVersionAndPortFailClosed() {
        XCTAssertNil(
            ReceiverEndpoint.decode(
                txtRecord: txtRecord(
                    id: "not-a-uuid",
                    name: "Lab Mac",
                    version: "1"
                ),
                host: "lab.local",
                port: 5555,
                serviceName: "invalid-id"
            )
        )
        XCTAssertNil(
            ReceiverEndpoint.decode(
                txtRecord: txtRecord(
                    id: stableID.uuidString,
                    name: "Lab Mac",
                    version: "2"
                ),
                host: "lab.local",
                port: 5555,
                serviceName: "invalid-version"
            )
        )
        XCTAssertNil(
            ReceiverEndpoint.decode(
                txtRecord: txtRecord(
                    id: stableID.uuidString,
                    name: "Lab Mac",
                    version: "1"
                ),
                host: "lab.local",
                port: 0,
                serviceName: "invalid-port"
            )
        )
        XCTAssertNil(
            ReceiverEndpoint.decode(
                txtRecord: NetService.data(
                    fromTXTRecord: [
                        "id": Data(stableID.uuidString.utf8),
                        "name": Data("Lab Mac".utf8),
                        "version": Data("1".utf8),
                        "unexpected": Data("value".utf8)
                    ]
                ),
                host: "lab.local",
                port: 5555,
                serviceName: "unexpected-key"
            )
        )
    }

    func testStoreDeduplicatesStableIdentityAndExpiresServices() {
        var store = ReceiverEndpointStore()
        let oldEndpoint = endpoint(host: "old.local")
        let newEndpoint = endpoint(host: "new.local")

        store.upsert(oldEndpoint, serviceKey: "service-old")
        store.upsert(newEndpoint, serviceKey: "service-new")

        XCTAssertEqual(store.endpoints, [newEndpoint])
        store.remove(serviceKey: "service-old")
        XCTAssertEqual(store.endpoints, [newEndpoint])
        store.remove(serviceKey: "service-new")
        XCTAssertTrue(store.endpoints.isEmpty)
    }

    func testPreferredIdentitySurvivesHostChangeWithoutConnecting() {
        var store = ReceiverEndpointStore()
        store.upsert(endpoint(host: "first.local"), serviceKey: "first")
        store.upsert(endpoint(host: "second.local"), serviceKey: "second")

        let preferred = store.preferred(
            stableID: stableID.uuidString.uppercased()
        )
        XCTAssertEqual(preferred?.host, "second.local")
    }

    func testManualAndDiscoveredTargetsShareExistingConnectionShape() {
        let manual = ReceiverConnectionTarget(
            host: "192.0.2.20",
            port: 5555
        )
        let discovered = endpoint(host: "lab.local").connectionTarget

        XCTAssertEqual(manual.host, "192.0.2.20")
        XCTAssertEqual(manual.port, 5555)
        XCTAssertEqual(discovered.host, "lab.local")
        XCTAssertEqual(discovered.port, 5555)
    }

    func testFirstSelectionPreservesEnteredTokenAndConnects() {
        let decision = ReceiverSelectionCredentialDecision.resolve(
            userEnteredToken: "  typed-token  ",
            storedToken: nil
        )
        XCTAssertEqual(decision.token, "typed-token")
    }

    func testKnownStableIdentityReusesStoredToken() {
        let decision = ReceiverSelectionCredentialDecision.resolve(
            userEnteredToken: "",
            storedToken: "stored-token"
        )
        XCTAssertEqual(decision.token, "stored-token")
    }

    func testNewReceiverWithoutTokenUsesOptionalEmptyCredential() {
        let decision = ReceiverSelectionCredentialDecision.resolve(
            userEnteredToken: "  ",
            storedToken: nil
        )
        XCTAssertEqual(decision.token, "")
    }

    func testPermissionAndGenericBrowserFailuresStayDistinct() {
        XCTAssertEqual(
            ReceiverDiscoveryState.browserFailure(errorCode: -72_008),
            .localNetworkDenied
        )
        XCTAssertEqual(
            ReceiverDiscoveryState.browserFailure(errorCode: -1),
            .failed
        )
        XCTAssertNotEqual(
            ReceiverDiscoveryState.networkUnavailable,
            ReceiverDiscoveryState.noReceivers
        )
    }

    func testRemovedServiceCannotBecomeCurrentAfterQueuedResolution() {
        var registry = ReceiverResolutionRegistry()
        let oldService = NSObject()
        let replacementService = NSObject()

        registry.register(serviceKey: "receiver", service: oldService)
        XCTAssertTrue(
            registry.isCurrent(serviceKey: "receiver", service: oldService)
        )

        registry.remove(serviceKey: "receiver")
        XCTAssertFalse(
            registry.isCurrent(serviceKey: "receiver", service: oldService)
        )

        registry.register(
            serviceKey: "receiver",
            service: replacementService
        )
        XCTAssertFalse(
            registry.isCurrent(serviceKey: "receiver", service: oldService)
        )
        XCTAssertTrue(
            registry.isCurrent(
                serviceKey: "receiver",
                service: replacementService
            )
        )
    }

    private func endpoint(host: String) -> ReceiverEndpoint {
        ReceiverEndpoint(
            stableID: stableID,
            displayName: "Lab Mac",
            host: host,
            port: 5555,
            serviceName: "UMI Capture Receiver"
        )
    }

    private func txtRecord(
        id: String,
        name: String,
        version: String
    ) -> Data {
        NetService.data(
            fromTXTRecord: [
                "id": Data(id.utf8),
                "name": Data(name.utf8),
                "version": Data(version.utf8)
            ]
        )
    }
}
