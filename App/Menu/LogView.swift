import SwiftUI
import TunnelKit

/// The last 500 lines a tunnel's process printed, refreshed every second.
struct LogView: View {
    let id: UUID?
    @Environment(TunnelStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let lines = id.map(store.log(for:)) ?? []
            ScrollView {
                Text(lines.isEmpty ? String(localized: "Nothing logged yet.") : lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .defaultScrollAnchor(.bottom)
        }
        .navigationTitle(id.flatMap { store.tunnel($0)?.name }.map { String(localized: "\($0) — Log") } ?? String(localized: "Log"))
    }
}
