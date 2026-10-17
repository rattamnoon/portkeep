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

/// Settings page for adding, naming, colouring and removing groups and tags. Any colour can be picked.
struct LabelsView: View {
    @Environment(TunnelStore.self) private var store

    var body: some View {
        Form {
            Section {
                ForEach(store.groups, id: \.self) { group in
                    let count = store.tunnelCount(inGroup: group)
                    LabelRow(name: group, hex: store.file.groupColors[group] ?? "#8E8E93", count: count,
                             rename: { store.renameGroup(group, to: $0) },
                             recolor: { store.setGroupColor(group, hex: $0) },
                             delete: count == 0 ? { store.deleteGroup(group) } : nil)
                }
                NewLabelRow(placeholder: "New group", existing: store.groups) { store.addGroup($0, hex: $1) }
            } header: {
                Text("Groups")
            } footer: {
                Text("Renaming a group moves its tunnels with it. A group can be removed once it's empty.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(store.file.allTags, id: \.self) { tag in
                    LabelRow(name: tag, hex: store.file.tagColor(tag), count: store.tunnelCount(withTag: tag),
                             rename: { store.renameTag(tag, to: $0) },
                             recolor: { store.setTagColor(tag, hex: $0) },
                             delete: { store.deleteTag(tag) })
                }
                NewLabelRow(placeholder: "New tag", existing: store.file.allTags) { store.addTag($0, hex: $1) }
            } header: {
                Text("Tags")
            } footer: {
                Text("Removing a tag takes it off every tunnel that has it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Groups & Tags")
    }
}

private struct LabelRow: View {
    let name: String
    let hex: String
    let count: Int
    let rename: (String) -> Void
    let recolor: (String) -> Void
    /// Nil when the label can't be removed (a group that still has tunnels).
    let delete: (() -> Void)?
    @State private var text: String

    init(name: String, hex: String, count: Int, rename: @escaping (String) -> Void,
         recolor: @escaping (String) -> Void, delete: (() -> Void)?) {
        self.name = name
        self.hex = hex
        self.count = count
        self.rename = rename
        self.recolor = recolor
        self.delete = delete
        _text = State(initialValue: name)
    }

    var body: some View {
        HStack(spacing: 10) {
            ColourControl(hex: hex, label: name, set: recolor)
            TextField("Name", text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            Text(count == 0 ? String(localized: "Unused") : count == 1 ? String(localized: "1 tunnel") : String(localized: "\(count) tunnels"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Button(role: .destructive) { delete?() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(delete == nil)
                .help(delete == nil ? Text("Move its tunnels to another group first") : Text("Remove \(name)"))
                .accessibilityLabel(Text("Remove \(name)"))
        }
        .onChange(of: name) { _, new in text = new }
        .onDisappear { commit() }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != name { rename(trimmed) } else { text = name }
    }
}

/// The last row of a section: type a name, pick a colour, Add.
private struct NewLabelRow: View {
    let placeholder: LocalizedStringKey
    let existing: [String]
    let add: (String, String) -> Void
    @State private var name = ""
    @State private var hex = LabelColor.presets[5]

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var duplicate: Bool { existing.contains { $0.lowercased() == trimmed.lowercased() } }

    var body: some View {
        HStack(spacing: 10) {
            ColourControl(hex: hex, label: trimmed) { hex = $0 }
            TextField(placeholder, text: $name, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .onChange(of: name) { _, new in
                    // Suggest a colour for the name until the user picks one.
                    if !new.isEmpty, LabelColor.presets.contains(hex) { hex = LabelColor.defaultHex(for: new) }
                }
            Button("Add", action: submit)
                .disabled(trimmed.isEmpty || duplicate)
        }
    }

    private func submit() {
        guard !trimmed.isEmpty, !duplicate else { return }
        add(trimmed, hex)
        name = ""
    }
}

/// System colour well for any colour, plus a menu of preset swatches.
private struct ColourControl: View {
    let hex: String
    let label: String
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ColorPicker("Colour of \(label)", selection: Binding(
                get: { Color(hex: hex) },
                set: { set($0.hex) }), supportsOpacity: false)
                .labelsHidden()
            Menu {
                ForEach(LabelColor.presets, id: \.self) { preset in
                    Button { set(preset) } label: {
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
    }
}
