// JobColorStripe — the 4pt leading edge stripe on every cell (and widget
// row), colored deterministically from `job_id`. Per docs/design-system.md
// §2.6 and the algorithm in §1.1.2 (implemented in Shared/Theme/JobColor.swift).

import SwiftUI

struct JobColorStripe: View {
    let jobId: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(JobColor.color(for: jobId, in: scheme))
            .frame(width: Space.xs)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack {
        HStack {
            JobColorStripe(jobId: "harmony-weekly-public-digest")
                .frame(height: 50)
            Text("Harmony")
        }
        HStack {
            JobColorStripe(jobId: "alberta-move-coordination")
                .frame(height: 50)
            Text("Alberta")
        }
    }
    .padding()
}
