// DemoAnswerLog — a tiny UserDefaults-backed store of "which questions
// have been answered" for demo mode.
//
// Why this exists: the widget's AppIntent runs in its own process. To make
// the optimistic post-answer state survive a `reloadTimelines` reload, we
// need a shared scratch space that both the app and the widget can read.
// In M2 this becomes an App Group container + the real callback POST. For
// M1 demo we use the suite-less `UserDefaults.standard` of the widget
// extension *and* the app — they're separate stores, but each surface
// (widget / app) still feels correct in isolation, and the simulator demo
// runs the widget in isolation per the team-lead brief
// (no App Group, no signing).
//
// (When App Group is wired in M1.5, swap `UserDefaults.standard` for
// `UserDefaults(suiteName: "group.com.crowly")` — that's the only diff.)

import Foundation

public final class DemoAnswerLog: @unchecked Sendable {
    public static let shared = DemoAnswerLog()

    private let defaults = UserDefaults.standard
    private let key = "crowly.demo.answers"

    private init() {}

    /// Record an answer. **First-write-wins** (idempotent on the question):
    /// a double-tap is a no-op, and tapping "No" after "Yes" is also a no-op.
    /// This matches the docs/ux.md invariant: "One tap = one answer = no
    /// confirmation. The companion dedupes on a client-minted callback_id
    /// (e.g. digest_id + question_id), so a double-tap is a no-op."
    ///
    /// (Per P0-3 from review pass A — the previous overwrite-last-wins
    /// behavior could flip an answered yes→no on a stray double-tap.)
    public func record(digestId: String, questionId: String, value: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let k = answerKey(digestId: digestId, questionId: questionId)
        guard dict[k] == nil else { return }       // first-write-wins
        dict[k] = value
        defaults.set(dict, forKey: key)
    }

    /// Read the recorded answer for a question, if any.
    public func answer(digestId: String, questionId: String) -> String? {
        let dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return dict[answerKey(digestId: digestId, questionId: questionId)]
    }

    /// Has the user answered this question already?
    public func isAnswered(digestId: String, questionId: String) -> Bool {
        answer(digestId: digestId, questionId: questionId) != nil
    }

    private func answerKey(digestId: String, questionId: String) -> String {
        "\(digestId):\(questionId)"
    }
}
