// InboxView — the root screen. Sectioned list of digests; pull-to-refresh;
// swipe-to-handle / archive / mute; demo-mode banner pinned to the safe area.
// Per docs/ux.md §Inbox and docs/design-system.md §3.1.

import SwiftUI

struct InboxView: View {
    @Environment(DigestStore.self) private var store
    @Environment(DeepLinkRouter.self) private var router
    @State private var query: String = ""
    /// Owns the navigation path so `.onOpenURL` can push a digest detail
    /// from outside the stack. Bug #2 fix from review pass B.
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.sectionedDigests(matching: query)) { section in
                    Section {
                        ForEach(section.digests) { digest in
                            NavigationLink(value: digest.id) {
                                DigestCell(
                                    digest: digest,
                                    questionOpenCount: store.openQuestionCount(for: digest),
                                    openLoopCounts: store.openLoopCounts(for: digest),
                                    state: store.statusDotState(for: digest)
                                )
                            }
                            .listRowInsets(EdgeInsets(
                                top: Space.xs, leading: Space.m,
                                bottom: Space.xs, trailing: Space.m
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    store.markHandled(digest)
                                } label: {
                                    Label("Mark handled", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    store.archive(digest)
                                } label: {
                                    Label("Archive", systemImage: "tray.and.arrow.down")
                                }
                                .tint(.gray)

                                Button {
                                    store.muteJob(digest.jobId)
                                } label: {
                                    Label("Mute job", systemImage: "bell.slash")
                                }
                                .tint(.orange)
                            }
                        }
                    } header: {
                        Text(section.title)
                            .font(.crowlyChip)
                            .foregroundStyle(.secondary)
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
            // P1-8: minimize the search bar so it stays out of the way on
            // long scrolls. Matches the design-system.md spec.
            .searchToolbarBehavior(.minimize)
            .refreshable { await store.refresh() }
            .safeAreaInset(edge: .top) {
                if store.isInDemoMode {
                    DemoModeBanner()
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.s)
                }
            }
            .overlay {
                if store.isEmpty(forQuery: query) {
                    ContentUnavailableView(
                        store.isInDemoMode ? "No digests yet" : "No matches",
                        systemImage: "tray",
                        description: Text(
                            store.isInDemoMode
                                ? "Send your first one from Hermes."
                                : "Try a different search."
                        )
                    )
                }
            }
            // Bug #2: when a deeplink arrives, push the digest detail.
            // We pop-to-root first so a stale stack doesn't shadow the
            // requested digest. `pendingDigestId` clears after handling so
            // the same link can fire again later.
            .onChange(of: router.pendingDigestId) { _, newId in
                guard let id = newId else { return }
                if store.digest(byId: id) != nil {
                    path = [id]
                }
                router.pendingDigestId = nil
            }
        }
    }
}

#Preview {
    InboxView()
        .environment(DigestStore())
        .environment(DeepLinkRouter())
}
