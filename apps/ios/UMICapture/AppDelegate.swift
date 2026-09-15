import SwiftUI

@main
struct UMICaptureApp: App {
    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        applyDocumentationValue(
            arguments,
            flag: "--umi-capture-docs-language",
            defaultsKey: "UMICapture.language"
        )
        applyDocumentationBool(
            arguments,
            flag: "--umi-capture-docs-source-acknowledged",
            defaultsKey: "UMICapture.sourceProvenanceAcknowledged"
        )
        applyDocumentationBool(
            arguments,
            flag: "--umi-capture-docs-tutorial-completed",
            defaultsKey: "UMICapture.tutorialCompleted"
        )
        #endif
    }

    var body: some Scene {
        WindowGroup {
            LaunchGateView()
        }
    }

    #if DEBUG
    private func applyDocumentationValue(
        _ arguments: [String],
        flag: String,
        defaultsKey: String
    ) {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return
        }
        UserDefaults.standard.set(arguments[index + 1], forKey: defaultsKey)
    }

    private func applyDocumentationBool(
        _ arguments: [String],
        flag: String,
        defaultsKey: String
    ) {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return
        }
        UserDefaults.standard.set(
            arguments[index + 1] == "true",
            forKey: defaultsKey
        )
    }
    #endif
}
