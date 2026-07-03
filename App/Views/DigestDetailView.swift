// DigestDetailView — the reader screen.
//
// Order: Bottom-line callout → Summary → Sections → Sources. The bottom-line
// callout sits at the top because it's the reason the user opened the digest.
// Auto-marks the digest read on appear; an Archive affordance lives in the
// bottom bar.

import SwiftUI

struct DigestDetailView: View {
    let digest: Digest
    @Environment(DigestStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    /// v2 content blocks worth rendering (empty/whitespace-only blocks dropped).
    /// When this is empty the view falls back to the v1 summary + sections.
    private var renderableBlocks: [ContentBlock] {
        digest.content.filter(\.isRenderable)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {

                // Bottom-line callout (opaque, tinted — not glass).
                if !digest.bottomLine.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Bottom line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.crowlyAccent)
                            .textCase(.uppercase)
                        Text(digest.bottomLine)
                            .font(.crowlyDetailCallout)
                            .foregroundStyle(Color.crowlyInk)
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                            .fill(Brand.orange.opacity(0.08))
                    )
                    .overlay(alignment: .leading) {
                        // Orange left accent bar
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.crowlyAccent)
                            .frame(width: 3)
                            .padding(.vertical, Space.s)
                    }
                }

                // Body. schema v2: if the digest carries structured `content`
                // blocks, render those; otherwise fall back to the v1
                // summary + sections shape. (A v2 emitter sends one or the
                // other; both are additive-only and never rendered together.)
                if !renderableBlocks.isEmpty {
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(Array(renderableBlocks.enumerated()), id: \.offset) { _, block in
                            ContentBlockView(block: block)
                        }
                    }
                } else {
                    // Summary — the optional prose paragraph above the section grid.
                    if let summary = digest.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.body)
                            .foregroundStyle(Color.crowlyInk)
                    }

                    // Body sections.
                    if !digest.sections.isEmpty {
                        VStack(alignment: .leading, spacing: Space.l) {
                            ForEach(digest.sections) { s in
                                VStack(alignment: .leading, spacing: Space.s) {
                                    Text(s.heading)
                                        .font(.crowlySectionTitle)
                                        .foregroundStyle(Color.crowlyInk)
                                    Text(s.body)
                                        .font(.body)
                                        .foregroundStyle(Color.crowlyInk)
                                }
                            }
                        }
                    }
                }

                // Sources.
                if !digest.sources.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        CrowlyDivider()
                            .padding(.bottom, Space.xs)
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.crowlyInkSoft)
                            .textCase(.uppercase)
                        ForEach(digest.sources) { src in
                            Button {
                                openURL(src.url)
                            } label: {
                                Label(src.title, systemImage: "arrow.up.right.square")
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.crowlyAccent)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.l)
            // Reserve space for the glass `.bottomBar` capsule so the
            // archive button doesn't overlap the last row.
            .padding(.bottom, 72)
        }
        .background(Color.crowlyBackground)
        .navigationTitle(digest.title)
        .navigationBarTitleDisplayMode(.large)
        .navigationSubtitle(digest.subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                Button {
                    store.archive(digest)
                    dismiss()
                } label: {
                    Label("Archive", systemImage: "tray.and.arrow.down")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        DigestDetailView(digest: DemoFixtures.aiNewsDigest)
            .environment(DigestStore())
    }
}
