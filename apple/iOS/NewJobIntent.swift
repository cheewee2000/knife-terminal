import AppIntents
import KnifeKit

/// "New Knife job" for Siri, Shortcuts and the Action Button: a request goes to the Mac
/// without opening the app. Siri asks for the request and takes it by voice.
struct NewJobIntent: AppIntent {
    static var title: LocalizedStringResource = "New Knife Job"
    static var description = IntentDescription("Send a request to your Mac. It runs in a job tab.")

    @Parameter(title: "Request", requestValueDialog: "What should Knife do?")
    var request: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // awaited here, not handed to the store: the app may be suspended the moment this returns
        try await CloudSync(role: "ios").sendJob(request)
        return .result(dialog: "Sent to your Mac.")
    }
}

struct KnifeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewJobIntent(),
                    phrases: ["New \(.applicationName) job", "Ask \(.applicationName)"],
                    shortTitle: "New Job", systemImageName: "apple.terminal")
    }
}
