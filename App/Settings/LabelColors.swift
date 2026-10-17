import AppKit
import SwiftUI
import TunnelKit

extension Color {
    /// A colour from "#RRGGBB"; gray when the string isn't one.
    init(hex: String) {
        if let (r, g, b) = LabelColor.components(hex) {
            self.init(.sRGB, red: r, green: g, blue: b)
        } else {
            self = .gray
        }
    }

    /// "#RRGGBB" in sRGB.
    var hex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return LabelColor.hex(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
    }
}

/// A small coloured capsule for a tag.
struct TagChip: View {
    let tag: String
    let hex: String
    var selected = false

    var body: some View {
        Text(tag)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(selected ? Color.white : Color(hex: hex))
            .background(Capsule().fill(Color(hex: hex).opacity(selected ? 1 : 0.18)))
    }
}

/// Settings page for naming and colouring groups and tags. Any colour can be picked.
struct LabelsView: View {
    @Environment(TunnelStore.self) private var store

    var body: some View {
        Form {
            Section {
                ForEach(store.groups, id: \.self) { group in
                    LabelRow(name: group, hex: store.file.groupColors[group] ?? "#8E8E93",
                             rename: { store.renameGroup(group, to: $0) },
                             recolor: { store.setGroupColor(group, hex: $0) })
                }
            } header: {
                Text("Groups")
            } footer: {
                Text("Rename a group here to move all of its tunnels.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if store.file.allTags.isEmpty {
                    Text("No tags yet. Add them to a tunnel, e.g. db, readonly.").foregroundStyle(.secondary)
                }
                ForEach(store.file.allTags, id: \.self) { tag in
                    LabelRow(name: tag, hex: store.file.tagColor(tag),
                             rename: { store.renameTag(tag, to: $0) },
                             recolor: { store.setTagColor(tag, hex: $0) })
                }
            } header: {
                Text("Tags")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Groups & Tags")
    }
}

private struct LabelRow: View {
    let name: String
    let hex: String
    let rename: (String) -> Void
    let recolor: (String) -> Void
    @State private var text: String

    init(name: String, hex: String, rename: @escaping (String) -> Void, recolor: @escaping (String) -> Void) {
        self.name = name
        self.hex = hex
        self.rename = rename
        self.recolor = recolor
        _text = State(initialValue: name)
    }

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("Colour of \(name)", selection: Binding(
                get: { Color(hex: hex) },
                set: { recolor($0.hex) }), supportsOpacity: false)
                .labelsHidden()
            TextField("Name", text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            Menu {
                ForEach(LabelColor.presets, id: \.self) { preset in
                    Button { recolor(preset) } label: {
                        Label { Text(verbatim: preset) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(hex: preset))
                        }
                    }
                }
            } label: {
                Image(systemName: "swatchpalette")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Preset colours")
        }
        .onChange(of: name) { _, new in text = new }
        .onDisappear { commit() }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != name { rename(trimmed) } else { text = name }
    }
}
