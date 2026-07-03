// InboxView — the root reader screen. Sectioned list of digests; pull-to-
// refresh; swipe-to-archive (with undo); demo-mode banner pinned to the safe
// area.

import SwiftUI

struct InboxView: View {
    @Environment(DigestStore.self) private var store
    @Environment(DeepLinkRouter.self) private var router
    @State private var query: String = ""
    /// Owns the navigation path so `.onOpenURL` can push a digest detail
    /// from outside the stack.
    @State private var path: [String] = []
    /// Undo target for the most recent archive. Synced from `store`
    /// whenever the swipe action fires; cleared after the toast times out.
    @State private var undoArchiveId: String?
    @State private var undoTask: Task<Void, Never>?
    /// Drives the pairing sheet. Surfaced from the demo-mode banner and
    /// the toolbar "Connect" button.
    @State private var showPairSheet: Bool = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.sectionedDigests(matching: query)) { section in
                    Section {
                        ForEach(section.digests) { digest in
                            NavigationLink(value: digest.id) {
                                DigestCell(
                                    digest: digest,
                                    state: store.statusDotState(for: digest)
                                )
                            }
                            .listRowInsets(EdgeInsets(
                                top: Space.xs, leading: Space.m,
                                bottom: Space.xs, trailing: Space.m
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    archive(digest)
                                } label: {
                                    Label("Archive", systemImage: "tray.and.arrow.down")
                                }
                                .tint(Color.crowlyMuted)
                            }
                        }
                    } header: {
                        Text(section.title)
                            .font(.crowlyChip)
                            .foregroundStyle(Color.crowlyInkSoft)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.crowlyBackground)
            .navigationTitle("Inbox")
            .navigationDestination(for: String.self) { id in
                if let digest = store.digest(byId: id) {
                    DigestDetailView(digest: digest)
                        .onAppear { store.markRead(digest) }
                }
            }
            .searchable(text: $query)
            // Minimize the search bar so it stays out of the way on long
            // scrolls. Matches the design-system spec.
            .searchToolbarBehavior(.minimize)
            .refreshable { await store.refresh() }
            .safeAreaInset(edge: .top) {
                if store.isInDemoMode {
                    Button { showPairSheet = true } label: {
                        DemoModeBanner()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                    .accessibilityHint("Tap to connect a Crowly companion.")
                }
            }
            .toolbar {
                if store.isInDemoMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showPairSheet = true
                        } label: {
                            Label("Connect inbox", systemImage: "link.badge.plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showPairSheet) {
                PairCompanionView()
                    .environment(store)
            }
            .safeAreaInset(edge: .bottom) {
                if undoArchiveId != nil {
                    UndoArchiveToast {
                        store.undoArchive()
                        cancelUndoToast()
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.bottom, Space.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: undoArchiveId)
            .overlay {
                if !store.hasLoaded {
                    // First live fetch in flight: a content-shaped skeleton,
                    // NOT the empty state. Without this the paired inbox flashes
                    // empty on cold launch and then pops in — and would briefly
                    // show the wrong "No matches" copy below.
                    InboxLoadingView()
                } else if store.isEmpty(forQuery: query) {
                    emptyState
                }
            }
            // When a deeplink arrives, push the digest detail. Pop-to-root
            // first so a stale stack doesn't shadow the requested digest.
            // `pendingDigestId` clears after handling so the same link can
            // fire again later.
            .onChange(of: router.pendingDigestId) { _, newId in
                guard let id = newId else { return }
                if store.digest(byId: id) != nil {
                    path = [id]
                }
                router.pendingDigestId = nil
            }
            // `crowly://pair` deeplink — undocumented surface used by the
            // run-crowly skill (and an App Reviewer with no other way to
            // tap a toolbar button) to present the pairing sheet.
            .onChange(of: router.pendingPair) { _, requested in
                guard requested else { return }
                showPairSheet = true
                router.pendingPair = false
            }
            // `crowly://inbox` deeplink — the large widget's "View all →"
            // footer. Pop any pushed digest detail so the user lands on the
            // inbox root. (Counter, not Bool: a tap while already at root
            // still fires this.)
            .onChange(of: router.popToInbox) { _, _ in
                path.removeAll()
            }
        }
    }

    /// The genuinely-empty state (fetch finished, nothing to show). Three
    /// distinct reasons get three distinct messages — never "No matches"
    /// unless the user is actually searching.
    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if store.isInDemoMode {
            ContentUnavailableView(
                "No digests yet",
                systemImage: "tray",
                description: Text("Demo digests will appear here.")
            )
        } else {
            // Paired, loaded, but the companion returned nothing.
            ContentUnavailableView(
                "Inbox is empty",
                systemImage: "tray",
                description: Text("New digests from your companion will show up here.")
            )
        }
    }

    private func archive(_ digest: Digest) {
        store.archive(digest)
        undoArchiveId = digest.id
        undoTask?.cancel()
        undoTask = Task { @MainActor in
            // 4-second undo window — long enough to react, short enough not
            // to litter the bottom of the screen.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { undoArchiveId = nil }
        }
    }

    private func cancelUndoToast() {
        undoArchiveId = nil
        undoTask?.cancel()
        undoTask = nil
    }
}

// MARK: - Undo toast

private struct UndoArchiveToast: View {
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(Color.crowlyInkSoft)
            Text("Archived")
                .font(.subheadline)
                .foregroundStyle(Color.crowlyInk)
            Spacer(minLength: 0)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.crowlyAccent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(
            Capsule().fill(Color.crowlySurface)
        )
        .overlay(
            Capsule().strokeBorder(Color.crowlyHairline, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Loading skeleton

/// First-load placeholder for the paired inbox. A short stack of cell-shaped
/// rows blurred out with `.redacted(reason: .placeholder)` — it shows the
/// SHAPE of what's coming (so there's no layout jump when real data lands) and
/// reads calmer than a bare centered spinner. Matches Apple's "placeholder
/// while loading" pattern; content-shaped, not a spinner over a blank screen.
private struct InboxLoadingView: View {
    var body: some View {
        VStack(spacing: Space.s) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonDigestRow()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.s)
        .redacted(reason: .placeholder)
        .accessibilityElement()
        .accessibilityLabel("Loading your inbox")
        // A11y: announce loading rather than reading out placeholder bars.
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A single cell-shaped placeholder row. Deliberately mirrors `DigestCell`'s
/// anatomy (job stripe + title line + meta line + two body lines) so the
/// redacted state lines up with the real content it's standing in for.
private struct SkeletonDigestRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.crowlyInkFaint)
                .frame(width: Space.xs, height: 44)

            VStack(alignment: .leading, spacing: Space.s) {
                Text("A representative digest title line")
                    .font(.crowlyCellTitle)
                    .lineLimit(1)
                Text("Just now")
                    .font(.footnote)
                Text("A two-line bottom line stands in for the digest's own summary so the skeleton matches the real cell height.")
                    .font(.crowlyCellBody)
                    .lineLimit(2)
            }
            .padding(.vertical, Space.s)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.crowlySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.crowlyHairline, lineWidth: 0.5)
        )
    }
}

#Preview("Inbox — demo") {
    InboxView()
        .environment(DigestStore())
        .environment(DeepLinkRouter())
}

#Preview("Inbox — loading skeleton") {
    InboxLoadingView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.crowlyBackground)
}
