import Combine

final class CaptureActionBus {
    static let shared = CaptureActionBus()

    private let subject = PassthroughSubject<ARAction, Never>()

    private init() {}

    var publisher: AnyPublisher<ARAction, Never> {
        subject.eraseToAnyPublisher()
    }

    func send(_ action: ARAction) {
        subject.send(action)
    }
}

