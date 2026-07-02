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
                                .tint(.gray)
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
                if store.isEmpty(forQuery: query) {
                    ContentUnavailableView(
                        store.isInDemoMode ? "No digests yet" : "No matches",
                        systemImage: "tray",
                        description: Text(
                            store.isInDemoMode
                                ? "Demo digests will appear here."
                                : "Try a different search."
                        )
                    )
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
                .foregroundStyle(.secondary)
            Text("Archived")
                .font(.subheadline)
            Spacer(minLength: 0)
            Button("Undo", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)               // [iOS 26]
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(
            Capsule().fill(Color.crowlySurface)
        )
        .overlay(
            Capsule().strokeBorder(.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    InboxView()
        .environment(DigestStore())
        .environment(DeepLinkRouter())
}
