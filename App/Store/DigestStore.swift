// DigestStore — the in-memory view-model that the app reads from.
//
// In M1 demo mode this is fed by `DemoFixtures` and answered entirely
// client-side. When real pairing arrives, this same store will be backed
// by HTTP/JSON to the user's companion — the UI surface doesn't change.
//
// What lives here:
//   - The canonical list of digests (newest-first)
//   - Per-question / per-action *answer state* (optimistic UI)
//   - Per-digest *read/handled/archived* state
//   - The active `RouteResolver` (capability-aware)
//   - Inbox sectioning by relative date
//
// Concurrency: @MainActor — all UI state changes happen on the main actor,
// which keeps Swift 6 strict-concurrency happy and matches the SwiftUI
// rendering model.

import SwiftUI
import Foundation
import Observation

@MainActor
@Observable
final class DigestStore {

    // MARK: - Inputs

    /// Demo-mode flag. Drives the demo banner and seeds the store with
    /// `DemoFixtures.digests`. M1 default is `true`.
    var isInDemoMode: Bool

    /// The active resolver. Built from `Capabilities` — in demo mode this is
    /// the canned `DemoCapabilities.standard`; in real mode it would come
    /// from `GET /capabilities`.
    var resolver: RouteResolver

    // MARK: - Backing state

    private(set) var digests: [Digest]

    /// Per-question optimistic answer state. **Keyed by `(digest.id,
    /// question.id)`** because fixture question ids ("q1") are reused
    /// across digests — a flat key on `question.id` causes state bleed
    /// from one digest into the next (P0-2 from review pass A).
    private var answerStates: [String: AnswerState] = [:]

    /// Per-action optimistic state. Same digest-scoped keying — `a1` is
    /// reused across digests.
    private var actionStates: [String: ActionState] = [:]

    /// Per-digest UI state (unread / read / handled / archived).
    private var digestStates: [String: DigestState] = [:]

    /// Muted job_ids — UI hides their push, NOT their content (mute is a
    /// push gate, not a filter, per CLAUDE.md). Tracked for the swipe action;
    /// the inbox does NOT filter on this.
    private(set) var mutedJobIds: Set<String> = []

    // MARK: - Init

    init(
        digests: [Digest] = DemoFixtures.digests,
        isInDemoMode: Bool = true,
        resolver: RouteResolver = RouteResolver(capabilities: DemoCapabilities.standard)
    ) {
        self.digests = digests
        self.isInDemoMode = isInDemoMode
        self.resolver = resolver
        // All digests start `.unread` so the inbox shows the right cue.
        for d in digests {
            self.digestStates[d.id] = .unread
        }
    }

    // MARK: - Lookups

    func digest(byId id: String) -> Digest? {
        digests.first(where: { $0.id == id })
    }

    // MARK: - Key helpers
    //
    // Per-question / per-action state is keyed by **(digest.id, child.id)**
    // because demo fixtures (and real digests) reuse short ids like `q1` and
    // `a1` across digests.

    private static func answerKey(digestId: String, questionId: String) -> String {
        "\(digestId):\(questionId)"
    }

    private static func actionKey(digestId: String, actionId: String) -> String {
        "\(digestId):\(actionId)"
    }

    // MARK: - State queries

    func answerState(digestId: String, questionId: String) -> AnswerState {
        answerStates[Self.answerKey(digestId: digestId, questionId: questionId)] ?? .unanswered
    }

    func actionState(digestId: String, actionId: String) -> ActionState {
        actionStates[Self.actionKey(digestId: digestId, actionId: actionId)] ?? .unresolved
    }

    func digestState(for digestId: String) -> DigestState {
        digestStates[digestId] ?? .unread
    }

    // MARK: - Counts for the cell

    /// Open question count for a digest (a question is "open" until an answer
    /// is recorded locally — or the whole digest is `.handled`, in which case
    /// chips decay to zero regardless of per-question state).
    func openQuestionCount(for digest: Digest) -> Int {
        if digestState(for: digest.id) == .handled { return 0 }
        return digest.questions
            .filter { answerState(digestId: digest.id, questionId: $0.id) == .unanswered }
            .count
    }

    /// Open action-item counts grouped by intent for a digest. Used by the
    /// chip row in `DigestCell`. Capability-aware intents that fall back to
    /// `.terminal` group under their *terminal* intent so the chip label
    /// matches the actual route the resolver will fire. A `.handled` digest
    /// reports zero open loops so the chip row decays — that's the "did the
    /// work" feel.
    func openLoopCounts(for digest: Digest) -> [Intent: Int] {
        if digestState(for: digest.id) == .handled { return [:] }
        var counts: [Intent: Int] = [:]
        for action in digest.actionItems
        where actionState(digestId: digest.id, actionId: action.id) == .unresolved {
            let resolution = resolver.resolve(action)
            counts[resolution.intent, default: 0] += 1
        }
        return counts
    }

    // MARK: - Status dot

    func statusDotState(for digest: Digest) -> StatusDot.State {
        switch digestState(for: digest.id) {
        case .unread:    return .unread
        case .read:
            let stillOpen = openQuestionCount(for: digest) > 0
                || openLoopCounts(for: digest).values.contains(where: { $0 > 0 })
            return stillOpen ? .readOpen : .handled
        case .handled:   return .handled
        case .archived:  return .archived
        }
    }

    // MARK: - Sections

    struct Section: Identifiable, Hashable {
        let id: String
        let title: String
        let digests: [Digest]
    }

    /// Open-loop digests first (urgency desc, then time desc); pure-info
    /// digests below. Then sectioned by relative date. Per docs/ux.md §Inbox.
    func sectionedDigests(matching query: String) -> [Section] {
        let now = Date()
        let cal = Calendar.current
        let filtered: [Digest] = {
            guard !query.isEmpty else { return digests }
            let q = query.lowercased()
            return digests.filter { d in
                d.title.lowercased().contains(q)
                    || d.bottomLine.lowercased().contains(q)
                    || d.summary?.lowercased().contains(q) == true
            }
        }()

        // Compute "openness" per digest first; that's the primary sort.
        let withOpenness: [(Digest, Bool)] = filtered.map { d in
            let openLoops = openQuestionCount(for: d) > 0
                || openLoopCounts(for: d).values.contains(where: { $0 > 0 })
            return (d, openLoops)
        }
        let sorted = withOpenness.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 && !rhs.1 }
            if lhs.0.urgency != rhs.0.urgency { return lhs.0.urgency > rhs.0.urgency }
            return lhs.0.createdAt > rhs.0.createdAt
        }.map { $0.0 }

        // Section by relative date.
        var sections: [String: [Digest]] = [:]
        for d in sorted {
            let key = sectionKey(for: d.createdAt, now: now, calendar: cal)
            sections[key, default: []].append(d)
        }

        let order = ["Today", "Yesterday", "This week", "Earlier"]
        return order.compactMap { key in
            guard let items = sections[key] else { return nil }
            return Section(id: key, title: key, digests: items)
        }
    }

    private func sectionKey(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
           date > weekAgo {
            return "This week"
        }
        return "Earlier"
    }

    // MARK: - RouteResolutions

    func resolution(forAnswer value: String, of question: Question) -> RouteResolution {
        resolver.resolve(forAnswer: value, of: question)
    }

    func resolution(for action: ActionItem) -> RouteResolution {
        resolver.resolve(action)
    }

    // MARK: - Mutations (optimistic; demo mode = client-side only)

    /// Answer a question. Optimistic: records the answer immediately so the
    /// row collapses into its `didResolve` state. Real-mode parity: POSTs the
    /// callback synchronously and flips to `.failed` on error (M2).
    func answer(_ question: Question, in digestId: String, value: String) {
        let resolution = resolver.resolve(forAnswer: value, of: question)
        let key = Self.answerKey(digestId: digestId, questionId: question.id)
        answerStates[key] = .answered(value: value, resolution: resolution)
    }

    /// Mark an action as executed (the route fired).
    func executeAction(_ action: ActionItem, in digestId: String) {
        let resolution = resolver.resolve(action)
        let key = Self.actionKey(digestId: digestId, actionId: action.id)
        actionStates[key] = .resolved(resolution: resolution)
    }

    /// Mark a digest as handled.
    ///
    /// Per the P0-4 fix: we no longer write fake `.answered("handled")`
    /// values into `answerStates`. That was producing wrong resolution
    /// previews ("Answered: handled — dismissed") on rows the user never
    /// touched. Instead, chip decay is driven entirely off
    /// `digestState == .handled` (see `openQuestionCount` / `openLoopCounts`
    /// above) so untouched rows stay visually open inside the detail view
    /// while the inbox chip row decays — which matches how a real
    /// state_change works.
    func markHandled(_ digest: Digest) {
        digestStates[digest.id] = .handled
    }

    func markRead(_ digest: Digest) {
        if digestStates[digest.id] == .unread || digestStates[digest.id] == nil {
            digestStates[digest.id] = .read
        }
    }

    func archive(_ digest: Digest) {
        digestStates[digest.id] = .archived
    }

    /// Mute suppresses *push* for the job — per CLAUDE.md, the inbox stays a
    /// durable archive. We track the set so a future push gate can read it.
    func muteJob(_ jobId: String) {
        mutedJobIds.insert(jobId)
    }

    // MARK: - Demo refresh (no-op; surface for `.refreshable`)

    func refresh() async {
        // No-op in demo mode; real mode hits the companion.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    var isEmpty: Bool { digests.isEmpty }

    func isEmpty(forQuery query: String) -> Bool {
        sectionedDigests(matching: query).isEmpty
    }
}

// MARK: - Local state types

/// Optimistic answer state on a single question.
enum AnswerState: Hashable {
    case unanswered
    case answered(value: String, resolution: RouteResolution)
    case failed(value: String, resolution: RouteResolution)

    var isResolved: Bool {
        switch self {
        case .answered: true
        case .failed, .unanswered: false
        }
    }

    var failed: Bool {
        if case .failed = self { return true } else { return false }
    }

    var value: String? {
        switch self {
        case .answered(let v, _), .failed(let v, _): return v
        case .unanswered: return nil
        }
    }

    var resolution: RouteResolution? {
        switch self {
        case .answered(_, let r), .failed(_, let r): return r
        case .unanswered: return nil
        }
    }
}

/// Optimistic action-item state.
enum ActionState: Hashable {
    case unresolved
    case resolved(resolution: RouteResolution)
    case failed(resolution: RouteResolution)

    var isResolved: Bool {
        switch self {
        case .resolved: true
        case .failed, .unresolved: false
        }
    }

    var resolution: RouteResolution? {
        switch self {
        case .resolved(let r), .failed(let r): return r
        case .unresolved: return nil
        }
    }
}
