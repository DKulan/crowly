// DemoFixtures — canned reader digests for Demo Mode.
//
// Crowly is a reader: cron-job outputs the user skims. These fixtures cover
// the positioning themes (AI news, weather, local community, reminders) and
// exercise:
//   - varied urgency (low / normal / high / urgent)
//   - schema **v2 structured content blocks** — every block type appears
//     across the set (weather is the showcase: callout + metrics + heading +
//     ordered list + divider + paragraph); AI-news mixes paragraph + list +
//     inline markdown; community mixes heading + callout.
//   - the v1 fallback shape (summary + sections) — market-pulse keeps it, so
//     the detail view's "content else summary/sections" branch is covered.
//   - pure bottom-line digests (no body, no sources) — the reminder.
//   - the extras passthrough (market-pulse carries a v2-only field).
//
// These fixtures double as the App Store marketing artifact, so they read like
// real digests. They're compiled into BOTH the app and the widget — the widget
// reads the same demo digests from Shared/, so no App Group or backend is
// needed to demo the reader.

import Foundation

public enum DemoFixtures {

    /// All canned digests, sorted newest-first.
    public static let digests: [Digest] = [
        aiNewsDigest,
        weatherDigest,
        communityDigest,
        reminderDigest,
        marketPulseDigest
    ]

    // MARK: - 1. AI news summary (the flagship "what's new" digest)

    public static let aiNewsDigest = Digest(
        schemaVersion: 2,
        id: "dgst_2026-06-29_ai-news",
        jobId: "ai-news-daily",
        source: "hermes-cron",
        title: "AI news — Monday roundup",
        // Today's date is 2026-06-29; pin to morning so the relative
        // timestamp reads "Today at 7 AM" when the demo runs.
        createdAt: dateFrom("2026-06-29T07:15:00-04:00"),
        urgency: .normal,
        bottomLine: "Two major model releases this weekend. Image-gen pricing keeps falling; safety-eval benchmarks getting a refresh in July.",
        // Summary retained (searchable — "safety benchmark" is exercised by the
        // search tests) even though `content` is present: search reads
        // title/bottom_line/summary, and this digest renders from `content`.
        summary: "Quiet weekend on the policy front; loud one on releases. Two frontier labs shipped updated flagship models within a day of each other, both leading on long-context reasoning. Separately, a coalition of eval houses announced a refresh of the public safety benchmark suite.",
        content: [
            .paragraph(text: "Quiet weekend on the policy front; **loud one on releases.** Two frontier labs shipped updated flagship models within a day of each other, both leading on long-context reasoning."),
            .heading(text: "Releases"),
            .list(style: .bullet, items: [
                "Two frontier-lab flagship updates landed — incremental gains on math + code, large jumps on long-context retrieval.",
                "Pricing per 1M tokens dropped roughly *30%* on both sides.",
            ]),
            .heading(text: "Evals"),
            .paragraph(text: "A coalition of eval houses announced a refresh of the public safety benchmark suite for July — adds adversarial prompt categories and a real-world-task harness. See [the announcement](https://crfm.stanford.edu/) for the submission window."),
        ],
        sources: [
            Source(
                title: "Anthropic announcements",
                url: URL(string: "https://www.anthropic.com/news")!
            ),
            Source(
                title: "Stanford CRFM — eval suite refresh",
                url: URL(string: "https://crfm.stanford.edu/")!
            )
        ]
    )

    // MARK: - 2. Weather digest (high urgency: a storm warning)

    public static let weatherDigest = Digest(
        schemaVersion: 2,
        id: "dgst_2026-06-29_weather",
        jobId: "weather-local",
        source: "hermes-cron",
        title: "Weather — severe thunderstorm watch",
        createdAt: dateFrom("2026-06-29T06:00:00-04:00"),
        // v2 showcase (see content below).
        urgency: .high,
        bottomLine: "Severe thunderstorm watch in effect 2 PM–9 PM. Gusts to 90 km/h possible; hail likely along the foothills.",
        // Showcase fixture: exercises every v2 block type — callout, metrics,
        // heading, ordered list, divider, paragraph.
        content: [
            .callout(
                variant: .warning,
                title: "Severe thunderstorm watch",
                text: "In effect **2 PM–9 PM**. Gusts to *90 km/h* and hail likely along the foothills. Secure loose patio items before noon."
            ),
            .metrics(items: [
                Metric(label: "Peak window", value: "4–7 PM"),
                Metric(label: "Max gust", value: "90 km/h"),
                Metric(label: "Confidence", value: "Mod–High"),
                Metric(label: "Hail risk", value: "Likely"),
            ]),
            .heading(text: "What to expect"),
            .list(style: .ordered, items: [
                "Cells fire mid-afternoon along the foothills and sweep east.",
                "The Calgary core sees the leading edge around 4 PM.",
                "Watch may upgrade to a warning if rotation is detected.",
            ]),
            .divider,
            .paragraph(text: "**Tomorrow:** clearer behind the front. Highs near 22°C with a light NW wind."),
        ],
        sources: [
            Source(
                title: "Environment Canada — Alerts",
                url: URL(string: "https://weather.gc.ca/warnings/")!
            )
        ]
    )

    // MARK: - 3. Local community update (the schema-shaped "what's happening")

    public static let communityDigest = Digest(
        schemaVersion: 2,
        id: "dgst_2026-06-28_community",
        jobId: "harmony-weekly-public-digest",
        source: "hermes-cron",
        title: "Harmony Community — weekly digest",
        createdAt: dateFrom("2026-06-28T09:00:00-04:00"),
        urgency: .low,
        bottomLine: "Council met Thursday — two new bylaw drafts in public comment, neither touching our parcel. Rec Society AGM Aug 12.",
        content: [
            .paragraph(text: "Quiet week. Two new bylaw drafts entered the public-comment window — both off-site levy revisions that *don't touch our parcel* directly."),
            .heading(text: "Bylaw watch"),
            .paragraph(text: "Regional off-site levy updates remain under review. The amendment text isn't public yet — staff report due late July."),
            .callout(
                variant: .info,
                title: "Save the date",
                text: "Harmony Recreation Society **AGM — Aug 12, 7 PM**, at the community hall. Light agenda: treasurer's report and one trustee seat up for election."
            ),
        ],
        sources: [
            Source(
                title: "Rocky View County Bylaws Under Review",
                url: URL(string: "https://www.rockyview.ca/government/bylaws/bylaws-under-review")!
            )
        ]
    )

    // MARK: - 4. Reminder digest (no sections, just a clear bottom_line)

    public static let reminderDigest = Digest(
        schemaVersion: 1,
        id: "dgst_2026-06-28_reminder",
        jobId: "reminders-daily",
        source: "hermes-cron",
        title: "Reminder — recycling pickup tomorrow",
        createdAt: dateFrom("2026-06-28T18:30:00-04:00"),
        urgency: .normal,
        bottomLine: "Recycling and yard waste pickup is tomorrow (Monday). Bins out by 7 AM.",
        sources: []
    )

    // MARK: - 5. Market pulse — pure-info, low urgency, with v2-extras
    //
    // Carries a `forecast_confidence` extras key so the round-trip test has
    // a real-world example of additive-only behavior.

    public static let marketPulseDigest = Digest(
        schemaVersion: 1,
        id: "dgst_2026-06-27_market-pulse",
        jobId: "market-pulse-weekly",
        source: "hermes-cron",
        title: "Market Pulse — weekly digest",
        createdAt: dateFrom("2026-06-27T07:30:00-04:00"),
        urgency: .low,
        bottomLine: "Nothing actionable. Two minor headlines flagged for context.",
        summary: "Equity volume light, fixed-income spreads steady. Nothing on the watch-list moved more than half a standard deviation.",
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
        sources: [
            Source(
                title: "BoC Rate Decision Notes",
                url: URL(string: "https://www.bankofcanada.ca/rates/")!
            )
        ],
        extras: [
            "forecast_confidence": .string("moderate")
        ]
    )

    // MARK: - Helpers

    private static func dateFrom(_ iso: String) -> Date {
        CrowlyISO8601.parse(iso) ?? Date()
    }
}
