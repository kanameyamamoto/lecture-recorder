// 講義の録音開始の確認画面と、出席履歴の画面

import SwiftUI

private let jpLocale = Locale(identifier: "ja_JP")

private func periodRange(_ periods: [String: String], _ p: Int) -> String {
    (periods[String(p)] ?? "").replacingOccurrences(of: "-", with: "〜")
}

// MARK: - 録音開始の確認画面（講義／フリー録音）

enum StartMode {
    case lecture   // 講義：時間割から授業・時限を選ぶ
    case other     // フリー録音（ゼミなど）：時限なし
}

final class StartPanelModel: ObservableObject {
    let mode: StartMode
    let classes: [ClassEntry]
    let names: [String]                // 選べる名前（重複なし）
    let periods: [String: String]
    let periodCount: Int
    let semester: String

    @Published var selectedName: String {
        didSet { if oldValue != selectedName { resetForSelectedName() } }
    }
    @Published var period: Int
    @Published var number: Int

    let editingStart: Date?            // 録音中の情報を変更するときは、その録音の開始時刻

    init(config: Config, mode: StartMode, defaultName: String?, defaultPeriod: Int?,
         initialNumber: Int? = nil, editingStart: Date? = nil) {
        self.editingStart = editingStart
        self.mode = mode
        classes = config.classes
        var list: [String] = []
        let source = mode == .lecture ? config.classes.map { $0.name } : config.otherKinds
        for n in source where !list.contains(n) { list.append(n) }
        names = list
        periods = config.periods
        let pc = max(1, config.periods.keys.compactMap { Int($0) }.max() ?? 6)
        periodCount = pc
        semester = config.currentSemester

        let name = defaultName.flatMap { list.contains($0) ? $0 : nil } ?? list.first ?? ""
        let options = StartPanelModel.periodOptions(classes: config.classes, name: name, periodCount: pc)
        selectedName = name
        period = defaultPeriod.flatMap { options.contains($0) ? $0 : nil } ?? options.first ?? 1
        number = initialNumber ?? Attendance.nextNumber(bucket: Attendance.bucket(for: name), name: name)
    }

    var isEditing: Bool { editingStart != nil }

    var title: String {
        if isEditing { return "録音中の情報を変更" }
        return mode == .lecture ? "講義の録音を開始" : "フリー録音を開始"
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func periodOptions(classes: [ClassEntry], name: String, periodCount: Int) -> [Int] {
        var result: [Int] = []
        for c in classes where c.name == name {
            for p in c.periods ?? [] where !result.contains(p) { result.append(p) }
        }
        return result.isEmpty ? Array(1...periodCount) : result.sorted()
    }

    var periodOptions: [Int] {
        Self.periodOptions(classes: classes, name: selectedName, periodCount: periodCount)
    }

    /// 講義のときだけ時限を使う
    var selectedPeriod: Int? { mode == .lecture ? period : nil }

    func periodLabel(_ p: Int) -> String {
        let r = periodRange(periods, p)
        return r.isEmpty ? "\(p)限" : "\(p)限（\(r)）"
    }

    private func resetForSelectedName() {
        period = periodOptions.first ?? 1
        number = Attendance.nextNumber(bucket: Attendance.bucket(for: selectedName), name: selectedName)
    }

    /// 今日のこのコマ（フリー録音は今日）がすでに記録されているか
    var alreadyRecorded: Bool {
        Attendance.isRecorded(bucket: Attendance.bucket(for: selectedName), name: selectedName,
                              date: Date(), period: selectedPeriod)
    }

    /// 前回までの出席数（今日のこのコマを録り直す場合、その分は除く）
    var previousAttendance: Int {
        let count = Attendance.entries(bucket: Attendance.bucket(for: selectedName), name: selectedName).count
        return alreadyRecorded ? max(0, count - 1) : count
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = jpLocale
        f.dateFormat = "yyyy/MM/dd（E）HH:mm"
        return f.string(from: date)
    }
}

struct StartPanelView: View {
    @ObservedObject var model: StartPanelModel
    var onStart: @MainActor (String, Int?, Int) -> Void   // 名前, 時限（フリー録音はnil）, 回数
    var onCancel: @MainActor () -> Void
    var onDiscard: (@MainActor () -> Void)? = nil         // 録音中の情報を変更する画面でだけ使う
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(model.title).font(.title2.bold())
                Spacer()
                Text(model.mode == .lecture ? model.semester : "学期とは関係なく共通")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.names.isEmpty {
                Text(model.mode == .lecture
                     ? "今の学期の時間割に授業がありません。メニューの「時間割を編集…」から登録してください。"
                     : "フリー録音が登録されていません。メニューの「時間割を編集…」の「フリー録音」から登録してください。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    row(model.isEditing ? "開始" : "日時") {
                        TimelineView(.periodic(from: Date(), by: 1)) { context in
                            if let start = model.editingStart {
                                Text("\(StartPanelModel.format(start))（録音中 \(StartPanelModel.elapsed(from: start, to: context.date))）")
                                    .monospacedDigit()
                            } else {
                                Text(StartPanelModel.format(context.date)).monospacedDigit()
                            }
                        }
                    }
                    row(model.mode == .lecture ? "授業" : "種類") {
                        Picker("", selection: $model.selectedName) {
                            ForEach(model.names, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if model.mode == .lecture {
                        row("時限") {
                            Picker("", selection: $model.period) {
                                ForEach(model.periodOptions, id: \.self) { p in
                                    Text(model.periodLabel(p)).tag(p)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    row("回数") {
                        HStack(spacing: 8) {
                            Text("#\(model.number)").font(.title3.bold()).monospacedDigit()
                            Stepper("", value: $model.number, in: 1...99).labelsHidden()
                            Text("前回＋1が自動で入ります").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    row("出席") {
                        HStack(spacing: 6) {
                            Text("\(model.previousAttendance) + 1").font(.title3.bold()).monospacedDigit()
                            Text("前回までの出席 ＋ 今回").font(.caption).foregroundStyle(.secondary)
                            if model.alreadyRecorded {
                                Text("（今日の分は記録済み）").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack {
                if model.isEditing, onDiscard != nil {
                    Button(role: .destructive) {
                        confirmDiscard = true
                    } label: {
                        Label("録音を破棄", systemImage: "trash")
                    }
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("キャンセル") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    onStart(model.selectedName, model.selectedPeriod, model.number)
                } label: {
                    if model.isEditing {
                        Label("変更を保存", systemImage: "checkmark.circle")
                    } else {
                        Label("録音開始", systemImage: "record.circle")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.names.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .endEditingOnBackgroundClick()
        .alert("この録音を破棄しますか？", isPresented: $confirmDiscard) {
            Button("破棄する", role: .destructive) { onDiscard?() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("録音中の音声は削除され、文字起こしも出席の記録もされません。元に戻せません。")
        }
    }

    /// 左にラベル、右に値。値はすべて同じ位置から左揃えで並べる
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 出席履歴

final class HistoryModel: ObservableObject {
    let periods: [String: String]
    let periodCount: Int
    private let configNames: [String: [String]]   // 区分 → 時間割に載っている授業名（並び順）
    private let configPeriods: [String: [String: [Int]]]   // 区分 → 授業名 → その授業のコマ

    @Published var buckets: [String]
    @Published var selectedBucket: String {
        didSet { if oldValue != selectedBucket { reloadNames() } }
    }
    @Published var names: [String] = []
    @Published var selectedName: String? = nil {
        didSet { if oldValue != selectedName { resetAddForm() } }
    }
    @Published private(set) var book: Attendance.Book = [:]

    // 記録の追加用
    @Published var addDate = Date()
    @Published var addPeriod = 0          // 0 = 時限なし
    @Published var addNumber = 1

    init(config: Config) {
        periods = config.periods
        periodCount = max(1, config.periods.keys.compactMap { Int($0) }.max() ?? 6)

        var map: [String: [String]] = [:]
        var periodMap: [String: [String: [Int]]] = [:]
        for s in config.semesters {
            var names: [String] = []
            var periodsByName: [String: [Int]] = [:]
            for c in s.classes {
                if !names.contains(c.name) { names.append(c.name) }
                for p in c.periods ?? [] where !(periodsByName[c.name] ?? []).contains(p) {
                    periodsByName[c.name, default: []].append(p)
                }
            }
            map[s.name] = names
            periodMap[s.name] = periodsByName.mapValues { $0.sorted() }
        }
        map[Attendance.commonBucket] = config.otherKinds
        configNames = map
        configPeriods = periodMap

        let loaded = Attendance.load()
        var list = config.semesters.map { $0.name }
        for key in loaded.keys.sorted() where key != Attendance.commonBucket && !list.contains(key) { list.append(key) }
        list.append(Attendance.commonBucket)
        buckets = list
        selectedBucket = config.currentSemester
        reload()
    }

    func reload() {
        book = Attendance.load()
        reloadNames()
    }

    private func reloadNames() {
        var list = configNames[selectedBucket] ?? []
        for key in (book[selectedBucket] ?? [:]).keys.sorted() where !list.contains(key) { list.append(key) }
        names = list
        if selectedName == nil || !list.contains(selectedName!) { selectedName = list.first }
        resetAddForm()
    }

    private func resetAddForm() {
        guard let name = selectedName else { return }
        addNumber = (entries(for: name).map { $0.number }.max() ?? 0) + 1
        addDate = Date()
        addPeriod = addPeriodOptions.first ?? 0
    }

    /// 選んでいる授業のコマ（1コマなら自動で入れて選ぶ欄は出さない、フリー録音は時限なし）
    var addPeriodOptions: [Int] {
        guard let name = selectedName else { return [] }
        return configPeriods[selectedBucket]?[name] ?? []
    }

    func entries(for name: String) -> [AttendanceEntry] {
        book[selectedBucket]?[name] ?? []
    }

    var selectedEntries: [AttendanceEntry] {
        selectedName.map { entries(for: $0) } ?? []
    }

    func bucketTitle(_ b: String) -> String {
        b == Attendance.commonBucket ? "フリー録音" : b
    }

    func delete(at index: Int) {
        guard let name = selectedName else { return }
        Attendance.delete(bucket: selectedBucket, name: name, at: index)
        reload()
    }

    /// 時間割に載っている授業か（載っていれば、記録を消しても一覧には残る）
    func isInTimetable(_ name: String) -> Bool {
        (configNames[selectedBucket] ?? []).contains(name)
    }

    func deleteClass(_ name: String) {
        Attendance.deleteClass(bucket: selectedBucket, name: name)
        if selectedName == name && !isInTimetable(name) { selectedName = nil }
        reload()
    }

    func add() {
        guard let name = selectedName else { return }
        Attendance.record(bucket: selectedBucket, name: name, date: addDate,
                          number: addNumber, period: addPeriod == 0 ? nil : addPeriod)
        reload()
    }

    func dateLabel(_ e: AttendanceEntry) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: e.date) else { return e.date }
        let f = DateFormatter()
        f.locale = jpLocale
        f.dateFormat = "yyyy/MM/dd（E）"
        return f.string(from: d)
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @State private var pendingDelete: Int?
    @State private var pendingClassDelete: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("区分").font(.headline)
                Picker("", selection: $model.selectedBucket) {
                    ForEach(model.buckets, id: \.self) { Text(model.bucketTitle($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 240)
                Spacer()
            }

            HStack(alignment: .top, spacing: 0) {
                List(selection: $model.selectedName) {
                    ForEach(model.names, id: \.self) { name in
                        HStack {
                            Text(name).lineLimit(1)
                            Spacer()
                            Text("\(model.entries(for: name).count)回")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(Optional(name))
                        .contextMenu {
                            Button("この授業の記録を削除…", role: .destructive) { pendingClassDelete = name }
                        }
                    }
                }
                .frame(width: 260)

                Divider()

                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 480)
        .endEditingOnBackgroundClick()
        .alert("この記録を削除しますか？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let i = pendingDelete { model.delete(at: i) }
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("出席数と、次の回数の初期値に反映されます。")
        }
        .alert("「\(pendingClassDelete ?? "")」の記録をすべて削除しますか？", isPresented: Binding(
            get: { pendingClassDelete != nil },
            set: { if !$0 { pendingClassDelete = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let name = pendingClassDelete { model.deleteClass(name) }
                pendingClassDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingClassDelete = nil }
        } message: {
            if let name = pendingClassDelete, model.isInTimetable(name) {
                Text("この授業の出席記録がすべて消えます。時間割に登録されている授業なので、一覧には0回で残ります。")
            } else {
                Text("この授業の出席記録がすべて消え、一覧からもなくなります。")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let name = model.selectedName {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.title3.bold())
                    Text("出席 \(model.selectedEntries.count) 回").foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        pendingClassDelete = name
                    } label: {
                        Label("この授業の記録を削除", systemImage: "trash")
                    }
                    .help("名前を間違えて登録した授業などを、記録ごと削除します")
                }

                HStack {
                    Text("日付").frame(width: 150, alignment: .leading)
                    Text("時刻").frame(width: 60, alignment: .leading)
                    Text("時限").frame(width: 50, alignment: .leading)
                    Text("回数").frame(width: 50, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.selectedEntries.isEmpty {
                            Text("まだ記録がありません").foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(Array(model.selectedEntries.enumerated()), id: \.offset) { index, e in
                            HStack {
                                Text(model.dateLabel(e)).frame(width: 150, alignment: .leading)
                                Text(e.time ?? "—").frame(width: 60, alignment: .leading)
                                Text(e.period.map { "\($0)限" } ?? "—").frame(width: 50, alignment: .leading)
                                Text("#\(e.number)").frame(width: 50, alignment: .leading)
                                Spacer()
                                Button {
                                    pendingDelete = index
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("この記録を削除")
                            }
                            .monospacedDigit()
                            Divider()
                        }
                    }
                }

                GroupBox("記録を追加（アプリを入れる前の分や、録音し忘れた回）") {
                    HStack(spacing: 10) {
                        DatePicker("", selection: $model.addDate, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                        if model.addPeriodOptions.count > 1 {
                            Picker("", selection: $model.addPeriod) {
                                ForEach(model.addPeriodOptions, id: \.self) { Text("\($0)限").tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 90)
                        }
                        Text("#\(model.addNumber)").monospacedDigit()
                        Stepper("", value: $model.addNumber, in: 1...99).labelsHidden()
                        Spacer()
                        Button("追加") { model.add() }
                    }
                    .padding(4)
                }
            }
            .padding(.leading, 16)
        } else {
            Text("記録する授業がありません").foregroundStyle(.secondary).padding()
        }
    }
}
