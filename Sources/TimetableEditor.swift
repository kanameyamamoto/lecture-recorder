// 時間割の編集画面（学期ごとに、曜日×時限のマス目へ授業名を入れる）

import SwiftUI
import AppKit

extension View {
    /// 入力欄以外の場所をクリックしたら、入力中の状態を解除する
    func endEditingOnBackgroundClick() -> some View {
        background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }
        )
    }
}

struct OtherKindItem: Identifiable {
    let id = UUID()
    var name: String
}

struct SemesterDraft: Identifiable {
    let id = UUID()
    var name: String
    let originalName: String?          // 既存の学期なら元の名前（名前変更の検出用）
    var cells: [String: String]        // "火-3" → "経営学"
    var undated: [ClassEntry]          // 曜日が決まっていない授業（そのまま残す）
}

final class TimetableModel: ObservableObject {
    static let days = ["月", "火", "水", "木", "金", "土"]
    static let maxPeriods = 8

    @Published var periodCount: Int
    @Published var starts: [Date]          // [0] = 1限（全学期共通）
    @Published var ends: [Date]
    @Published var semesters: [SemesterDraft]
    @Published var selectedID: UUID        // 編集中の学期
    @Published var activeID: UUID          // 録音に使う学期
    @Published var others: [OtherKindItem] // フリー録音（学期とは関係なく共通）

    init(config: Config) {
        var drafts: [SemesterDraft] = []
        var maxUsed = 0
        for semester in config.semesters {
            var cells: [String: String] = [:]
            for entry in semester.classes {
                guard let day = entry.day else { continue }
                for p in entry.periods ?? [] {
                    cells["\(day)-\(p)"] = entry.name
                    maxUsed = max(maxUsed, p)
                }
            }
            drafts.append(SemesterDraft(name: semester.name, originalName: semester.name, cells: cells,
                                        undated: semester.classes.filter { $0.day == nil }))
        }
        if drafts.isEmpty {
            drafts.append(SemesterDraft(name: config.currentSemester, originalName: nil, cells: [:], undated: []))
        }
        let maxConfigured = config.periods.keys.compactMap { Int($0) }.max() ?? 0

        var starts: [Date] = []
        var ends: [Date] = []
        var lastEnd = 9 * 60 - 10
        for p in 1...Self.maxPeriods {
            var s = lastEnd + 10
            var e = s + 100
            if let range = config.periods[String(p)] {
                let parts = range.split(separator: "-").map(String.init)
                if parts.count == 2, let ps = Self.minutes(parts[0]), let pe = Self.minutes(parts[1]) {
                    s = ps
                    e = pe
                }
            }
            starts.append(Self.date(minutes: s))
            ends.append(Self.date(minutes: e))
            lastEnd = e
        }

        let active = drafts.first { $0.name == config.currentSemester } ?? drafts[0]
        self.periodCount = min(Self.maxPeriods, max(1, maxConfigured, maxUsed))
        self.starts = starts
        self.ends = ends
        self.semesters = drafts
        self.selectedID = active.id
        self.activeID = active.id
        self.others = config.otherKinds.map { OtherKindItem(name: $0) }
    }

    // MARK: 学期

    var selectedIndex: Int? { semesters.firstIndex { $0.id == selectedID } }

    var selectedName: Binding<String> {
        Binding(
            get: { self.selectedIndex.map { self.semesters[$0].name } ?? "" },
            set: { value in if let i = self.selectedIndex { self.semesters[i].name = value } }
        )
    }

    func pickerTitle(_ s: SemesterDraft) -> String {
        let name = s.name.trimmingCharacters(in: .whitespaces).isEmpty ? "（名前なし）" : s.name
        return s.id == activeID ? "\(name)（使用中）" : name
    }

    /// 新しい学期を追加（名前は最後の学期の次の学期を自動で付ける。時間割は空）
    func addSemester() {
        let draft = SemesterDraft(name: Self.nextSemesterName(after: semesters.last?.name ?? ""),
                                  originalName: nil, cells: [:], undated: [])
        semesters.append(draft)
        selectedID = draft.id
    }

    func deleteSelected() {
        guard semesters.count > 1, let i = selectedIndex else { return }
        let removed = semesters.remove(at: i)
        if removed.id == activeID { activeID = semesters[0].id }
        selectedID = semesters[min(i, semesters.count - 1)].id
    }

    static func nextSemesterName(after name: String) -> String {
        let pattern = #"(\d{4})年(前期|後期)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let yr = Range(m.range(at: 1), in: name), let tr = Range(m.range(at: 2), in: name),
           let year = Int(name[yr]) {
            return name[tr] == "前期" ? "\(year)年後期" : "\(year + 1)年前期"
        }
        return "新しい学期"
    }

    // MARK: マス目

    func binding(day: String, period: Int) -> Binding<String> {
        Binding(
            get: {
                guard let i = self.selectedIndex else { return "" }
                return self.semesters[i].cells["\(day)-\(period)"] ?? ""
            },
            set: { value in
                guard let i = self.selectedIndex else { return }
                self.semesters[i].cells["\(day)-\(period)"] = value
            }
        )
    }

    func otherNameBinding(id: UUID) -> Binding<String> {
        Binding(
            get: { self.others.first { $0.id == id }?.name ?? "" },
            set: { value in
                if let i = self.others.firstIndex(where: { $0.id == id }) { self.others[i].name = value }
            }
        )
    }

    // MARK: 保存

    /// 編集内容を設定に書き戻す。同じ曜日で同じ授業名が入ったコマは1つの授業（2コマ続き）にまとめる
    func apply(to config: inout Config) {
        var periods: [String: String] = [:]
        for p in 1...periodCount {
            periods[String(p)] = "\(Self.hhmm(starts[p - 1]))-\(Self.hhmm(ends[p - 1]))"
        }

        var result: [Semester] = []
        var usedNames: Set<String> = []
        var activeName = config.currentSemester
        for draft in semesters {
            // 名前が空・重複していたら番号を付けて区別する
            var name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "新しい学期" }
            var unique = name
            var n = 2
            while usedNames.contains(unique) { unique = "\(name)（\(n)）"; n += 1 }
            usedNames.insert(unique)

            if let old = draft.originalName, old != unique {
                Attendance.renameBucket(from: old, to: unique)
            }
            if draft.id == activeID { activeName = unique }
            result.append(Semester(name: unique, classes: classes(from: draft)))
        }

        var kinds: [String] = []
        for item in others {
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !kinds.contains(name) { kinds.append(name) }
        }

        config.periods = periods
        config.semesters = result
        config.currentSemester = activeName
        config.otherKinds = kinds
    }

    private func classes(from draft: SemesterDraft) -> [ClassEntry] {
        var classes: [ClassEntry] = []
        for day in Self.days {
            var order: [String] = []
            var slots: [String: [Int]] = [:]
            for p in 1...periodCount {
                let name = (draft.cells["\(day)-\(p)"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                if slots[name] == nil { order.append(name) }
                slots[name, default: []].append(p)
            }
            for name in order {
                classes.append(ClassEntry(name: name, day: day, periods: slots[name]))
            }
        }
        return classes + draft.undated
    }

    // MARK: 時刻の変換

    static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    static func date(minutes: Int) -> Date {
        let m = max(0, min(minutes, 23 * 60 + 59))
        return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    static func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

struct TimetableView: View {
    @ObservedObject var model: TimetableModel
    @State private var isRenaming = false
    @State private var confirmDelete = false
    var onSave: @MainActor () -> Void
    var onCancel: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            semesterBar
            Divider()

            HStack(spacing: 12) {
                Text("時限の数").font(.headline)
                Stepper(value: $model.periodCount, in: 1...TimetableModel.maxPeriods) {
                    Text("\(model.periodCount)限まで")
                }
                Text("時限の時刻はすべての学期で共通です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            grid
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Text("授業名を入れたマスが登録されます（空欄は授業なし）。2コマ続きの授業は、続くコマに同じ授業名を入れてください。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            othersSection

            HStack {
                Spacer()
                Button("キャンセル") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { onSave() }
            }
        }
        .padding(18)
        .frame(minWidth: 1000, idealWidth: 1040)   // 幅の目安（これを基準に折り返す）
        .fixedSize(horizontal: false, vertical: true)
        .endEditingOnBackgroundClick()
    }

    // 学期の切り替え・追加・名前変更・削除
    private var semesterBar: some View {
        HStack(spacing: 10) {
            Text("学期").font(.headline)
            Picker("", selection: $model.selectedID) {
                ForEach(model.semesters) { s in
                    Text(model.pickerTitle(s)).tag(s.id)
                }
            }
            .labelsHidden()
            .frame(width: 200)
            .onReceive(model.$selectedID) { _ in isRenaming = false }

            if isRenaming {
                TextField("学期の名前", text: model.selectedName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { isRenaming = false }
                Button("完了") { isRenaming = false }
            } else {
                Button {
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("学期の名前を変更")
            }

            if model.selectedID == model.activeID {
                Label("録音に使用中", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("この学期を録音に使う") { model.activeID = model.selectedID }
            }

            Spacer()

            Button {
                model.addSemester()
                isRenaming = true   // 追加した学期はすぐ名前を直せるように
            } label: {
                Label("新しい学期", systemImage: "plus")
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(model.semesters.count <= 1)
        }
        .alert("「\(model.selectedName.wrappedValue)」を削除しますか？", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { model.deleteSelected() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この学期の時間割が消えます（「保存」を押したときに確定します）。出席履歴は残ります。")
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text("時限・時刻").font(.caption).foregroundStyle(.secondary)
                ForEach(TimetableModel.days, id: \.self) { day in
                    Text(day).font(.headline).frame(minWidth: 90, maxWidth: .infinity)
                }
            }
            Divider()
            ForEach(1...model.periodCount, id: \.self) { p in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p)限").font(.subheadline.bold())
                        HStack(spacing: 2) {
                            DatePicker("", selection: $model.starts[p - 1], displayedComponents: .hourAndMinute)
                                .labelsHidden()
                            Text("〜").font(.caption)
                            DatePicker("", selection: $model.ends[p - 1], displayedComponents: .hourAndMinute)
                                .labelsHidden()
                        }
                    }
                    ForEach(TimetableModel.days, id: \.self) { day in
                        TextField("", text: model.binding(day: day, period: p))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 90, maxWidth: .infinity)
                            .help(model.binding(day: day, period: p).wrappedValue)
                    }
                }
            }
        }
    }

    // フリー録音（学期とは関係なく共通）
    private var othersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("フリー録音").font(.headline)
                Text("学期とは関係なく共通です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 横に並べて、端まで行ったら次の行へ折り返す
            FlowLayout(spacing: 12, lineSpacing: 8) {
                ForEach(model.others) { item in
                    HStack(spacing: 4) {
                        TextField("例：ゼミ", text: model.otherNameBinding(id: item.id))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Button {
                            model.others.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("削除")
                    }
                }
                Button {
                    model.others.append(OtherKindItem(name: ""))
                } label: {
                    Label("追加", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
            }
        }
    }
}

/// 子ビューを左から横に並べ、幅が足りなくなったら次の行に折り返すレイアウト
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 幅が決まっていないときも1行に伸びすぎないよう、目安の幅で折り返す
        let maxWidth = (proposal.width.flatMap { $0.isFinite ? $0 : nil }) ?? 900
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        let width = (proposal.width.flatMap { $0.isFinite ? $0 : nil }) ?? min(widest, maxWidth)
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
