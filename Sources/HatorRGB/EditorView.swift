import SwiftUI
import AppKit
import HatorKit

private let cell: CGFloat = 40
private let gap: CGFloat = 4

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var brush: Color = .cyan
    @State private var showAllSlots = false
    @State private var calibrating = false
    @State private var renaming: SlotRef?
    @State private var presetName = ""

    private let swatches: [RGB] = [
        RGB(255, 0, 0), RGB(255, 128, 0), RGB(255, 230, 0), RGB(0, 255, 0), RGB(0, 255, 200),
        RGB(0, 120, 255), RGB(140, 0, 255), RGB(255, 0, 160), .white, .black,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            KeyGrid(showAllSlots: showAllSlots, onPaint: paint, onRename: { renaming = SlotRef(id: $0) })
            Text("Клік або протягування — фарбувати · ⌥-клік — взяти колір з клавіші · правий клік — перейменувати / сховати")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            presets
        }
        .padding(18)
        .onAppear { model.state.mode = .perKey }
        .sheet(isPresented: $calibrating) { CalibrationView().environmentObject(model) }
        .sheet(item: $renaming) { ref in RenameView(slot: ref.id).environmentObject(model) }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ColorPicker("Пензель", selection: $brush, supportsOpacity: false)
            ForEach(swatches, id: \.self) { c in
                Button { brush = c.color } label: {
                    RoundedRectangle(cornerRadius: 4).fill(c.color)
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 20)
            Button("Залити все") { fillAll(RGB(brush)) }
            Button("Очистити") { fillAll(.black) }
            Spacer()
            Toggle("Усі слоти", isOn: $showAllSlots).toggleStyle(.checkbox)
                .help("Показати слоти без назви (порожні місця матриці)")
            Button("Калібрувати розкладку…") { calibrating = true }
        }
    }

    private var presets: some View {
        HStack {
            Text("Пресети:").foregroundStyle(.secondary)
            ForEach(model.state.presets) { p in
                Button(p.name) { model.load(p) }
                    .contextMenu { Button("Видалити", role: .destructive) { model.delete(p) } }
            }
            Spacer()
            TextField("Назва", text: $presetName).frame(width: 140)
            Button("Зберегти пресет") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                model.savePreset(named: name.isEmpty ? "Пресет \(model.state.presets.count + 1)" : name)
                presetName = ""
            }
        }
    }

    private func paint(_ slot: Int, pick: Bool) {
        if pick {
            brush = model.state.perKey[slot].color
        } else {
            let c = RGB(brush)
            if model.state.perKey[slot] != c { model.state.perKey[slot] = c }
        }
    }

    private func fillAll(_ c: RGB) {
        var colors = model.state.perKey
        for i in colors.indices where model.state.layout.labels[i] != nil || showAllSlots { colors[i] = c }
        model.state.perKey = colors
    }
}

struct SlotRef: Identifiable { let id: Int }

struct KeyGrid: View {
    @EnvironmentObject var model: AppModel
    let showAllSlots: Bool
    let onPaint: (Int, Bool) -> Void
    let onRename: (Int) -> Void

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<HatorProtocol.rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<HatorProtocol.columns, id: \.self) { col in
                        keyCell(KeyLayout.slot(row: row, column: col))
                    }
                }
            }
        }
        .coordinateSpace(name: "grid")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
                .onChanged { v in
                    let col = Int(v.location.x / (cell + gap)), row = Int(v.location.y / (cell + gap))
                    guard (0..<HatorProtocol.rows).contains(row), (0..<HatorProtocol.columns).contains(col) else { return }
                    let slot = KeyLayout.slot(row: row, column: col)
                    guard showAllSlots || model.state.layout.labels[slot] != nil else { return }
                    onPaint(slot, NSEvent.modifierFlags.contains(.option))
                }
        )
    }

    @ViewBuilder
    private func keyCell(_ slot: Int) -> some View {
        let label = model.state.layout.labels[slot]
        let color = model.state.perKey[slot]
        if label != nil || showAllSlots {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(label == nil ? Color.secondary : Color.black.opacity(0.25),
                                      style: StrokeStyle(lineWidth: 1, dash: label == nil ? [3] : []))
                )
                .overlay(
                    Text(label ?? "\(slot)")
                        .font(.system(size: (label?.count ?? 0) > 3 ? 9 : 12, weight: .medium))
                        .foregroundStyle(label == nil ? Color.secondary : color.labelColor)
                        .minimumScaleFactor(0.6)
                        .padding(2)
                )
                .frame(width: cell, height: cell)
                .contextMenu {
                    Button("Перейменувати…") { onRename(slot) }
                    if label != nil {
                        Button("Сховати (немає клавіші)") { model.state.layout.labels[slot] = nil }
                    }
                }
        } else {
            Color.clear.frame(width: cell, height: cell)
        }
    }
}

struct RenameView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let slot: Int
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Назва для слота \(slot)").font(.headline)
            TextField("напр. Fn", text: $text).frame(width: 220).onSubmit(save)
            HStack {
                Button("Скасувати") { dismiss() }
                Spacer()
                Button("Зберегти", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear { text = model.state.layout.labels[slot] ?? "" }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        model.state.layout.labels[slot] = t.isEmpty ? nil : t
        dismiss()
    }
}
