// 録音履歴：これまでの録音と、その状態（録音中・文字起こし待ち・完了・失敗など）を一覧で見る
//
// 録音ごとの状態は ~/Library/Application Support/LectureRecorder/recordings.json に残す
// （音声は文字起こし後に一定日数で消えるが、履歴は残る）

import AppKit
import SwiftUI

// MARK: - 記録

struct RecordingRecord: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recording      // 録音中
        case waiting        // 文字起こし待ち
        case transcribing   // 文字起こし中
        case done           // 完了
        case failed         // 何度やってもできなかった（自動ではもう試さない）
        case broken         // 音声が壊れていた
    }

    var id: String            // 録音フォルダの名前
    var name: String
    var kind: String
    var number: Int?
    var start: Date
    var end: Date?
    var status: Status
    var failures: Int
    var lastError: String?
    var transcript: String?   // 保存した文字起こしの場所
    var method: String?       // どうやって文字起こししたか

    init(id: String, meta: RecordingMeta, status: Status) {
        self.id = id
        name = meta.name
        kind = meta.kind
        number = meta.number
        start = meta.start
        end = meta.end
        self.status = status
        failures = 0
    }

    /// 音声が今ある場所（消えていれば nil）
    var audioURL: URL? {
        let fm = FileManager.default
        for dir in [Paths.audio, Paths.audioDone, Paths.audioBroken] {
            let url = dir.appendingPathComponent(id)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// 文字起こしのファイル。講義ノートにまとめ終わると Inbox から隣の Done に移されるので、そちらも探す
    var transcriptURL: URL? {
        guard let t = transcript else { return nil }
        let url = URL(fileURLWithPath: t)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        let done = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Done", isDirectory: true).appendingPathComponent(url.lastPathComponent)
        return fm.fileExists(atPath: done.path) ? done : nil
    }
}

enum RecordingLog {
    static var url: URL { Paths.support.appendingPathComponent("recordings.json") }

    static func load() -> [RecordingRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecordingRecord].self, from: data)) ?? []
    }

    static func save(_ records: [RecordingRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) { try? data.write(to: url, options: .atomic) }
    }

    /// 録音の記録を書き換える（なければメタ情報から作る）
    static func update(_ audio: URL, meta: RecordingMeta? = nil, _ change: (inout RecordingRecord) -> Void) {
        var records = load()
        let id = audio.lastPathComponent
        if let i = records.firstIndex(where: { $0.id == id }) {
            if let meta {
                records[i].name = meta.name
                records[i].kind = meta.kind
                records[i].number = meta.number
                records[i].start = meta.start
                records[i].end = meta.end
            }
            change(&records[i])
        } else {
            guard let m = meta ?? (try? RecordingMeta.load(for: audio)) else { return }
            var r = RecordingRecord(id: id, meta: m, status: .waiting)
            change(&r)
            records.append(r)
        }
        save(records)
    }

    static func record(for audio: URL) -> RecordingRecord? {
        load().first { $0.id == audio.lastPathComponent }
    }

    static func remove(id: String) {
        save(load().filter { $0.id != id })
    }

    /// 起動時：途中で止まっていた状態を直し、記録のない録音（以前からあるもの）を足す
    static func sync(pending: [URL]) {
        var records = load()
        let pendingIDs = Set(pending.map { $0.lastPathComponent })
        for i in records.indices where [.recording, .transcribing, .waiting].contains(records[i].status) {
            if pendingIDs.contains(records[i].id) {
                records[i].status = .waiting
            } else if FileManager.default.fileExists(atPath: Paths.audioDone.appendingPathComponent(records[i].id).path) {
                records[i].status = .done
            } else {
                records[i].status = .failed
                records[i].lastError = "音声が見つかりません"
            }
        }
        let known = Set(records.map(\.id))
        for audio in pending where !known.contains(audio.lastPathComponent) {
            if let meta = try? RecordingMeta.load(for: audio) {
                records.append(RecordingRecord(id: audio.lastPathComponent, meta: meta, status: .waiting))
            }
        }
        save(records)
    }
}

// MARK: - 画面

@MainActor
final class RecordingHistoryModel: ObservableObject {
    @Published private(set) var records: [RecordingRecord] = []

    let retry: (RecordingRecord) -> Void
    let delete: (RecordingRecord) -> Void

    init(retry: @escaping (RecordingRecord) -> Void, delete: @escaping (RecordingRecord) -> Void) {
        self.retry = retry
        self.delete = delete
        reload()
    }

    func reload() {
        records = RecordingLog.load().sorted { $0.start > $1.start }
    }
}

struct RecordingHistoryView: View {
    @ObservedObject var model: RecordingHistoryModel
    @State private var pendingDelete: RecordingRecord?

    var body: some View {
        Group {
            if model.records.isEmpty {
                Text("まだ録音がありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.records) { r in
                    row(r).padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .alert("この録音を削除しますか？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("削除", role: .destructive) {
                if let r = pendingDelete { model.delete(r) }
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("音声と履歴が消えます。保存済みの文字起こしは消えません。")
        }
    }

    private func row(_ r: RecordingRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.name).font(.headline).lineLimit(1)
                    if let n = r.number { Text("#\(n)").foregroundStyle(.secondary) }
                }
                Text(subtitle(r)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                if let e = r.lastError, r.status == .failed || r.status == .broken || (r.status == .waiting && r.failures > 0) {
                    Text(e).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            status(r)
            HStack(spacing: 10) {
                if let t = r.transcriptURL {
                    Button { NSWorkspace.shared.open(t) } label: { Image(systemName: "doc.text") }
                        .help("文字起こしを開く")
                }
                if let a = r.audioURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([a]) } label: { Image(systemName: "folder") }
                        .help("音声をFinderで表示")
                    if [.done, .failed, .waiting].contains(r.status) {
                        Button { model.retry(r) } label: { Image(systemName: "arrow.clockwise") }
                            .help("もう一度文字起こしする")
                    }
                }
                if r.status != .recording && r.status != .transcribing {
                    Button { pendingDelete = r } label: { Image(systemName: "trash") }
                        .help("削除")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func subtitle(_ r: RecordingRecord) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d（E）HH:mm"
        var s = f.string(from: r.start)
        if let end = r.end {
            s += "・\(max(1, Int(end.timeIntervalSince(r.start) / 60)))分"
        }
        if let m = r.method, r.status == .done { s += "・\(m)" }
        return s
    }

    @ViewBuilder
    private func status(_ r: RecordingRecord) -> some View {
        switch r.status {
        case .recording:
            Label("録音中", systemImage: "record.circle").foregroundStyle(.red)
        case .waiting:
            Text(r.failures > 0 ? "やり直し待ち（\(r.failures)回失敗）" : "文字起こし待ち").foregroundStyle(.secondary)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("文字起こし中")
            }
            .foregroundStyle(.blue)
        case .done:
            Label("完了", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label("できませんでした", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .broken:
            Label("音声が壊れていた", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
