import Foundation
import UIKit

final class LocalStartCueController {
    typealias FeedbackAction = () -> Void

    private let queue: DispatchQueue
    private let cueInterval: TimeInterval
    private let feedbackAction: FeedbackAction
    private let lock = NSLock()
    private var generation = 0
    private var active = false
    private var pendingWorkItems: [DispatchWorkItem] = []

    init(
        queue: DispatchQueue = .main,
        cueInterval: TimeInterval = 1.0,
        feedbackAction: FeedbackAction? = nil
    ) {
        self.queue = queue
        self.cueInterval = cueInterval

        if let feedbackAction {
            self.feedbackAction = feedbackAction
        } else {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            self.feedbackAction = {
                generator.prepare()
                generator.impactOccurred(intensity: 0.75)
                generator.prepare()
            }
        }
    }

    var isActive: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return active
    }

    func start(
        onCountdown: @escaping (Int) -> Void,
        onCompletion: @escaping () -> Void
    ) {
        cancel()

        let token: Int
        lock.lock()
        generation += 1
        token = generation
        active = true
        lock.unlock()

        let twoCue = makeWorkItem(token: token) { [weak self] in
            onCountdown(2)
            self?.feedbackAction()
        }
        let oneCue = makeWorkItem(token: token) { [weak self] in
            onCountdown(1)
            self?.feedbackAction()
        }
        let completion = makeWorkItem(
            token: token,
            completesSequence: true,
            action: onCompletion
        )

        lock.lock()
        pendingWorkItems = [twoCue, oneCue, completion]
        lock.unlock()

        queue.async(execute: twoCue)
        queue.asyncAfter(
            deadline: .now() + cueInterval,
            execute: oneCue
        )
        queue.asyncAfter(
            deadline: .now() + cueInterval * 2,
            execute: completion
        )
    }

    func cancel() {
        let items: [DispatchWorkItem]
        lock.lock()
        generation += 1
        active = false
        items = pendingWorkItems
        pendingWorkItems.removeAll()
        lock.unlock()
        items.forEach {
            $0.cancel()
        }
    }

    func playFormalStartFeedback() {
        if Thread.isMainThread {
            feedbackAction()
        } else {
            queue.async { [feedbackAction] in
                feedbackAction()
            }
        }
    }

    private func makeWorkItem(
        token: Int,
        completesSequence: Bool = false,
        action: @escaping () -> Void
    ) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.lock.lock()
            let shouldRun =
                self.active
                && self.generation == token
            if completesSequence && shouldRun {
                self.active = false
                self.pendingWorkItems.removeAll()
            }
            self.lock.unlock()

            guard shouldRun else {
                return
            }
            action()
        }
    }
}

final class SynchronizedBoundaryFeedbackController {
    typealias FeedbackAction = (GroupCaptureCommandName) -> Void

    private let feedbackAction: FeedbackAction
    private var playedCommandIDs = Set<String>()

    init(feedbackAction: FeedbackAction? = nil) {
        if let feedbackAction {
            self.feedbackAction = feedbackAction
        } else {
            self.feedbackAction = { command in
                switch command {
                case .start:
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.prepare()
                    generator.impactOccurred(intensity: 0.9)
                case .stop:
                    let generator = UINotificationFeedbackGenerator()
                    generator.prepare()
                    generator.notificationOccurred(.success)
                case .prepare, .pause, .resume:
                    break
                }
            }
        }
    }

    func play(command: GroupCaptureCommandName, commandID: String) {
        guard command == .start || command == .stop,
              playedCommandIDs.insert(commandID).inserted
        else { return }
        feedbackAction(command)
    }

    func reset() {
        playedCommandIDs.removeAll(keepingCapacity: true)
    }
}
