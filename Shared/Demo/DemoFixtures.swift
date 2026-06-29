// DemoFixtures — canned digests used by Demo Mode.
//
// Requirements from the team-lead brief:
//   - ≥3 canned digests
//   - open-loop yes_no questions
//   - action items
//   - at least one pure-info digest (no open loops)
//   - one with parent_question_id set
//
// These fixtures are compiled into BOTH the app and the widget — the widget
// reads the SAME demo digests from Shared/, so no App Group or backend is
// needed to demo the bound loop.

import Foundation

public enum DemoFixtures {

    /// All canned digests, sorted newest-first.
    public static let digests: [Digest] = [
        harmonyDigest,
        albertaMoveDigest,
        pureInfoDigest,
        followupResultDigest
    ]

    // MARK: - 1. Harmony Community Digest (the schema.md example)
    //
    // One open yes_no question + one task action item + a real source.
    // The widget's `systemMedium` will surface the open question here.

    public static let harmonyDigest = Digest(
        schemaVersion: 1,
        id: "dgst_2026-06-29_harmony",
        jobId: "harmony-weekly-public-digest",
        source: "hermes-cron",
        title: "Harmony Community Digest",
        // Today's date is 2026-06-29; pinning the hour at 09:00 EDT so the
        // relative timestamp reads "Today at 9 AM" instead of "in 3 hours"
        // when the demo runs in the morning (Bug from review pass B).
        createdAt: dateFrom("2026-06-29T09:00:00-04:00"),
        urgency: .low,
        bottomLine: "No urgent action items. County bylaws under review remain worth watching.",
        summary: "Council met Thursday. Two new bylaw drafts entered the public-comment window — none touch our parcel directly. The off-site levy revisions are still circulating. Recreation Society AGM is Aug 12.",
        sections: [
            DigestSection(
                heading: "Bylaw watch",
                body: "Regional off-site levy updates remain under review. The amendment text isn't public yet — staff report due late July."
            ),
            DigestSection(
                heading: "Events",
                body: "Harmony Recreation Society AGM on Aug 12 at the community hall."
            )
        ],
        actionItems: [
            ActionItem(
                id: "a1",
                text: "Confirm Interlane EV9 drop-off window",
                route: TolerantIntent(intent: .task, raw: "task"),
                hints: [
                    "project": .string("Alberta Move"),
                    "labels": .array([.string("@hermes"), .string("@vendor")])
                ]
            )
        ],
        questions: [
            Question(
                id: "q1",
                text: "Should I start tracking the off-site levy bylaw as a recurring watch?",
                replyKind: .yesNo,
                onAnswer: [
                    "yes": OnAnswerLeg(
                        route: TolerantIntent(intent: .task, raw: "task"),
                        hints: ["text": .string("Set up recurring bylaw watch")]
                    ),
                    "no": OnAnswerLeg(
                        route: TolerantIntent(intent: Intent.none, raw: "none"),
                        hints: nil
                    )
                ]
            )
        ],
        sources: [
            Source(
                title: "Rocky View County Bylaws Under Review",
                url: URL(string: "https://www.rockyview.ca/government/bylaws/bylaws-under-review")!
            )
        ]
    )

    // MARK: - 2. Alberta Move Digest
    //
    // High urgency. One open yes_no question (followup), one action (note),
    // one action (task). Demonstrates the followup intent + mixed routes.

    public static let albertaMoveDigest = Digest(
        schemaVersion: 1,
        id: "dgst_2026-06-28_alberta-move",
        jobId: "alberta-move-coordination",
        source: "hermes-cron",
        title: "Alberta Move — week before drop-off",
        createdAt: dateFrom("2026-06-28T08:15:00-04:00"),
        urgency: .high,
        bottomLine: "Interlane confirmed the EV9 window. Calgary keys still pending on the seller side.",
        summary: "Interlane wrote in overnight confirming Wednesday 14:00–16:00 as the drop-off window. The seller's lawyer hasn't responded to the key-handoff email from Friday.",
        sections: [
            DigestSection(
                heading: "Logistics",
                body: "EV9 transit pickup is Thursday morning at the depot. Sticker tags arrived."
            ),
            DigestSection(
                heading: "Outstanding",
                body: "Key handoff window with the Calgary seller's lawyer remains unscheduled."
            )
        ],
        actionItems: [
            ActionItem(
                id: "a1",
                text: "File the EV9 transport receipt scan",
                route: TolerantIntent(intent: .note, raw: "note"),
                hints: [
                    "project": .string("Alberta Move"),
                    "labels": .array([.string("receipts")])
                ]
            ),
            ActionItem(
                id: "a2",
                text: "Forward the lawyer's email to the relocation folder",
                route: TolerantIntent(intent: .task, raw: "task"),
                hints: [
                    "project": .string("Alberta Move"),
                    "due": .string("2026-07-01")
                ]
            )
        ],
        questions: [
            Question(
                id: "q1",
                text: "Should I draft a polite nudge to the seller's lawyer about the key handoff window?",
                replyKind: .yesNo,
                onAnswer: [
                    "yes": OnAnswerLeg(
                        route: TolerantIntent(intent: .followup, raw: "followup"),
                        hints: ["context": .string("Polite, low-pressure tone. Reference Friday's thread.")]
                    ),
                    "no": OnAnswerLeg(
                        route: TolerantIntent(intent: Intent.none, raw: "none"),
                        hints: nil
                    )
                ]
            )
        ],
        sources: []
    )

    // MARK: - 3. Pure-info digest (no open loops)
    //
    // Per the brief: "at least one pure-info digest." No questions, no
    // action_items — proves the inbox sort order (open loops → pure-info)
    // and the status-dot `.handled` state on arrival.

    public static let pureInfoDigest = Digest(
        schemaVersion: 1,
        id: "dgst_2026-06-27_market-pulse",
        jobId: "market-pulse-weekly",
        source: "hermes-cron",
        title: "Market Pulse — weekly digest",
        createdAt: dateFrom("2026-06-27T07:30:00-04:00"),
        urgency: .low,
        bottomLine: "Nothing actionable. Two minor headlines flagged for context.",
        summary: "Equity volume light, fixed-income spreads steady. Nothing in the watch-list moved more than half a standard deviation.",
        sections: [
            DigestSection(
                heading: "Watch list",
                body: "All three names within their normal-volatility envelope."
            ),
            DigestSection(
                heading: "Context",
                body: "Minor headline activity around regional infrastructure spending. Nothing on the trade list."
            )
        ],
        actionItems: [],
        questions: [],
        sources: [
            Source(
                title: "BoC Rate Decision Notes",
                url: URL(string: "https://www.bankofcanada.ca/rates/")!
            )
        ]
    )

    // MARK: - 4. Followup-result digest
    //
    // Demonstrates `parent_question_id` — this digest is the result of a
    // previous followup answer. Older clients ignore the field; newer ones
    // render "in reply to your earlier answer about X" (M2 polish; M1
    // proves the field round-trips).

    public static let followupResultDigest = Digest(
        schemaVersion: 1,
        id: "dgst_2026-06-26_lawyer-followup",
        jobId: "alberta-move-coordination",
        source: "hermes-followup",
        title: "Draft: nudge to seller's lawyer",
        createdAt: dateFrom("2026-06-26T09:42:00-04:00"),
        urgency: .normal,
        bottomLine: "Draft ready. Three lines, low-pressure. Send as-is or tweak?",
        summary: "Generated draft for review. The original ask referenced Friday's thread and asks for two candidate windows.",
        sections: [
            DigestSection(
                heading: "Draft",
                body: "Hi — circling back on the key-handoff window. Could you suggest two Wednesday or Thursday slots that work? Happy to make either side of the workday."
            )
        ],
        actionItems: [
            ActionItem(
                id: "a1",
                text: "Send the draft as-is",
                route: TolerantIntent(intent: .task, raw: "task"),
                hints: [
                    "project": .string("Alberta Move")
                ]
            )
        ],
        questions: [
            Question(
                id: "q1",
                text: "Send this draft as is?",
                replyKind: .yesNo,
                onAnswer: [
                    "yes": OnAnswerLeg(
                        route: TolerantIntent(intent: .task, raw: "task"),
                        hints: ["text": .string("Send the lawyer nudge")]
                    ),
                    "no": OnAnswerLeg(
                        route: TolerantIntent(intent: Intent.none, raw: "none"),
                        hints: nil
                    )
                ]
            )
        ],
        sources: [],
        parentQuestionId: "q1"      // The originating question from the previous Alberta digest
    )

    // MARK: - Helpers

    private static func dateFrom(_ iso: String) -> Date {
        CrowlyISO8601.parse(iso) ?? Date()
    }
}
