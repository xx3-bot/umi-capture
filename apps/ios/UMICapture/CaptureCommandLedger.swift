import Foundation

enum CaptureCommandDisposition: Equatable {
    case execute
    case duplicate(previousState: String)
    case staleGeneration
    case conflictingCommandID
}

struct CaptureCommandLedger {
    private struct Key: Hashable {
        let sessionID: String
        let commandID: String
    }

    private var latestGenerationBySession: [String: Int] = [:]
    private var commandByKey: [Key: GroupCaptureCommandName] = [:]
    private var stateByKey: [Key: String] = [:]

    mutating func disposition(
        for command: GroupCaptureCommand
    ) -> CaptureCommandDisposition {
        let latest = latestGenerationBySession[command.sessionID] ?? -1
        guard command.generation >= latest else {
            return .staleGeneration
        }
        let key = Key(
            sessionID: command.sessionID,
            commandID: command.commandID
        )
        if let existing = commandByKey[key] {
            guard existing == command.command else {
                return .conflictingCommandID
            }
            return .duplicate(
                previousState: stateByKey[key] ?? "received"
            )
        }
        latestGenerationBySession[command.sessionID] = command.generation
        commandByKey[key] = command.command
        stateByKey[key] = "received"
        return .execute
    }

    mutating func record(
        state: String,
        for command: GroupCaptureCommand
    ) {
        let key = Key(
            sessionID: command.sessionID,
            commandID: command.commandID
        )
        guard commandByKey[key] == command.command else {
            return
        }
        stateByKey[key] = state
    }

    mutating func reset() {
        latestGenerationBySession.removeAll()
        commandByKey.removeAll()
        stateByKey.removeAll()
    }
}
