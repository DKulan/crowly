// AnswerQuestionIntent — the single AppIntent that records a question answer.
// Designed to be the same struct fired from:
//   - the widget's `Button(intent:)`
//   - the app's in-detail Yes/No buttons (M2 may switch to this for free
//     Siri / Shortcuts coverage)
//   - notification actions (M2)
//
// One intent, three call sites — per docs/ux.md §iOS specifics.
//
// In M1 demo mode the intent does NOT call a network. It writes to a tiny
// shared store (a UserDefaults-backed answer log) so a second widget
// reload reflects the optimistic state. When real pairing arrives, it'll
// POST the callback through the companion.

import AppIntents
import WidgetKit
import Foundation

/// Records a user's answer to a question. Returns immediately on demo mode;
/// real-mode POSTs the callback per docs/schema.md §2.
public struct AnswerQuestionIntent: AppIntent {
    public static let title: LocalizedStringResource = "Answer a Crowly question"
    public static let description = IntentDescription(
        "Record a yes/no answer to a question in your Crowly inbox."
    )

    /// Runs silently in the background by default — no app launch. The
    /// widget's tap experience depends on this.
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Digest ID")
    public var digestId: String

    @Parameter(title: "Question ID")
    public var questionId: String

    @Parameter(title: "Answer")
    public var value: String

    public init() {}

    public init(digestId: String, questionId: String, value: String) {
        self.digestId = digestId
        self.questionId = questionId
        self.value = value
    }

    public func perform() async throws -> some IntentResult {
        // M1 demo: record the answer in the shared store so the widget's
        // next timeline reload reflects it.
        DemoAnswerLog.shared.record(
            digestId: digestId,
            questionId: questionId,
            value: value
        )
        // Reload the widget so the row collapses to its post-answer state.
        WidgetCenter.shared.reloadTimelines(ofKind: "CrowlyOpenLoops")
        return .result()
    }
}
