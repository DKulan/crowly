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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {

                // Bottom-line callout (opaque, tinted — not glass).
                if !digest.bottomLine.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Bottom line")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(digest.bottomLine)
                            .font(.crowlyDetailCallout)
                            .foregroundStyle(.primary)
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    )
                }

                // Summary — the optional prose paragraph above the section grid.
                if let summary = digest.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary)
                }

                // Body sections.
                if !digest.sections.isEmpty {
                    VStack(alignment: .leading, spacing: Space.l) {
                        ForEach(digest.sections) { s in
                            VStack(alignment: .leading, spacing: Space.s) {
                                Text(s.heading).font(.crowlyCellTitle)
                                Text(s.body).font(.body)
                            }
                        }
                    }
                }

                // Sources.
                if !digest.sources.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Sources")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(digest.sources) { src in
                            Button {
                                openURL(src.url)
                            } label: {
                                Label(src.title, systemImage: "arrow.up.right.square")
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
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
