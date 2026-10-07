// LectureRecorder — メニューバーから録音 → Mac内で文字起こし → Googleドライブに保存
// ビルド: ./build.sh
// 設定: ~/Library/Application Support/LectureRecorder/config.json（メニューの「時間割を編集…」）

import Cocoa
import AVFoundation
import Speech
import UserNotifications
import ServiceManagement
import SwiftUI

// MARK: - 設定

struct ClassEntry: Codable {
    var name: String
    var day: String?        // "月"〜"土"。曜日が決まっていない授業は null
    var periods: [Int]?     // 例: [1, 2]
}

struct Semester: Codable {
    var name: String                   // "2026年後期"
    var classes: [ClassEntry]
}

struct Config: Codable {
    var outputFolder: String?          // 空なら Googleドライブ/マイドライブ/LectureRecorder を自動で探す
    var periods: [String: String]      // "1": "09:00-10:40"（全学期共通）
    var semesters: [Semester]          // 学期ごとの時間割
    var currentSemester: String        // 録音に使う学期
    var otherKinds: [String]           // フリー録音の種類（例: ゼミ）。学期とは関係なく共通
    var keepAudioDays: Int             // 文字起こし済みの音声を残す日数

    /// 録音に使う学期の授業
    var classes: [ClassEntry] {
        get { semesters.first { $0.name == currentSemester }?.classes ?? semesters.first?.classes ?? [] }
        set {
            if let i = semesters.firstIndex(where: { $0.name == currentSemester }) {
                semesters[i].classes = newValue
            } else {
                semesters.append(Semester(name: currentSemester, classes: newValue))
            }
        }
    }

    init(outputFolder: String?, periods: [String: String], semesters: [Semester],
         currentSemester: String, otherKinds: [String], keepAudioDays: Int) {
        self.outputFolder = outputFolder
        self.periods = periods
        self.semesters = semesters
        self.currentSemester = currentSemester
        self.otherKinds = otherKinds
        self.keepAudioDays = keepAudioDays
    }

    private enum CodingKeys: String, CodingKey {
        case outputFolder, periods, semesters, currentSemester, otherKinds, keepAudioDays, classes
    }

    /// 学期の仕組みを入れる前の設定ファイル（classes だけのもの）も読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder)
        periods = try c.decodeIfPresent([String: String].self, forKey: .periods) ?? d.periods
        otherKinds = try c.decodeIfPresent([String].self, forKey: .otherKinds) ?? d.otherKinds
        keepAudioDays = try c.decodeIfPresent(Int.self, forKey: .keepAudioDays) ?? d.keepAudioDays
        if let s = try c.decodeIfPresent([Semester].self, forKey: .semesters), !s.isEmpty {
            semesters = s
            let current = try c.decodeIfPresent(String.self, forKey: .currentSemester)
            currentSemester = s.contains(where: { $0.name == current }) ? current! : s[0].name
        } else {
            let old = try c.decodeIfPresent([ClassEntry].self, forKey: .classes) ?? d.semesters[0].classes
            semesters = [Semester(name: d.currentSemester, classes: old)]
            currentSemester = d.currentSemester
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(outputFolder, forKey: .outputFolder)
        try c.encode(periods, forKey: .periods)
        try c.encode(semesters, forKey: .semesters)
        try c.encode(currentSemester, forKey: .currentSemester)
        try c.encode(otherKinds, forKey: .otherKinds)
        try c.encode(keepAudioDays, forKey: .keepAudioDays)
    }

    /// 日付から学期名を作る（4〜9月は前期、10〜3月は後期。1〜3月は前の年度の後期）
    static func semesterName(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        let year = c.year ?? 2026
        let month = c.month ?? 4
        if (4...9).contains(month) { return "\(year)年前期" }
        return month >= 10 ? "\(year)年後期" : "\(year - 1)年後期"
    }

    static let `default` = Config(
        outputFolder: nil,
        periods: [
            "1": "09:00-10:40",
            "2": "10:50-12:30",
            "3": "13:20-15:00",
            "4": "15:10-16:50",
            "5": "17:00-18:40",
            "6": "18:50-20:30",
        ],
        semesters: [Semester(name: Config.semesterName(for: Date()), classes: [])],
        currentSemester: Config.semesterName(for: Date()),
        otherKinds: [],
        keepAudioDays: 14
    )
}

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LectureRecorder", isDirectory: true)
    }()
    static var config: URL { support.appendingPathComponent("config.json") }
    static var audio: URL { support.appendingPathComponent("audio", isDirectory: true) }
    static var audioDone: URL { audio.appendingPathComponent("done", isDirectory: true) }
    static var audioBroken: URL { audio.appendingPathComponent("broken", isDirectory: true) }   // 読み込めない録音

    /// Googleドライブ（パソコン版）のマイドライブを探す
    static func googleDriveRoot() -> URL? {
        let fm = FileManager.default
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(atPath: cloud.path) else { return nil }
        for item in items.sorted() where item.hasPrefix("GoogleDrive-") {
            for myDrive in ["マイドライブ", "My Drive"] {
                let url = cloud.appendingPathComponent(item).appendingPathComponent(myDrive, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
            }
        }
        return nil
    }
}

// MARK: - 出席記録（学期 → 授業名 → 出席した日と、その日が第何回か）

struct AttendanceEntry: Codable {
    var date: String     // "2026-10-07"
    var time: String?    // 録音を始めた時刻 "15:12"
    var number: Int      // 第何回の授業か
    var period: Int?     // 何限目か
}

enum Attendance {
    typealias Book = [String: [String: [AttendanceEntry]]]   // 学期（フリー録音は「フリー録音」）→ 授業名 → 記録

    static let commonBucket = "フリー録音"
    static var currentSemester = Config.default.currentSemester
    static var commonNames: Set<String> = []

    static var url: URL { Paths.support.appendingPathComponent("attendance.json") }

    /// フリー録音（ゼミなど）は学期に関係なく共通、講義は今の学期ごとに数える
    static func bucket(for name: String) -> String {
        commonNames.contains(name) ? commonBucket : currentSemester
    }

    static let oldCommonBucket = "講義以外"   // 以前の名前（読み込み時に付け替える）

    static func load() -> Book {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if var book = try? JSONDecoder().decode(Book.self, from: data) {
            if let old = book.removeValue(forKey: oldCommonBucket) {
                book[commonBucket, default: [:]].merge(old) { a, b in a + b }
                save(book)
            }
            return book
        }
        // 学期で分ける前の形式（授業名 → 記録）なら、今の学期・フリー録音に振り分ける
        if let flat = try? JSONDecoder().decode([String: [AttendanceEntry]].self, from: data) {
            var book: Book = [:]
            for (name, list) in flat { book[bucket(for: name), default: [:]][name] = list }
            return book
        }
        return [:]
    }

    static func save(_ book: Book) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(book) { try? data.write(to: url) }
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func entries(bucket: String, name: String) -> [AttendanceEntry] {
        load()[bucket]?[name] ?? []
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// 同じ日・同じコマを2回録音しても1回と数える（回数と時刻は後の方で上書き）
    static func record(bucket: String, name: String, date: Date, number: Int, period: Int?) {
        var book = load()
        var list = book[bucket]?[name] ?? []
        let d = day(date)
        let t = time(date)
        if let i = list.firstIndex(where: { $0.date == d && $0.period == period }) {
            list[i].number = number
            list[i].time = t
        } else {
            list.append(AttendanceEntry(date: d, time: t, number: number, period: period))
        }
        list.sort { ($0.date, $0.time ?? "", $0.period ?? 0) < ($1.date, $1.time ?? "", $1.period ?? 0) }
        book[bucket, default: [:]][name] = list
        save(book)
    }

    /// その日・そのコマがすでに記録済みか
    static func isRecorded(bucket: String, name: String, date: Date, period: Int?) -> Bool {
        let d = day(date)
        return entries(bucket: bucket, name: name).contains { $0.date == d && $0.period == period }
    }

    /// 授業ごと記録を消す（名前を間違えて登録した授業など）
    static func deleteClass(bucket: String, name: String) {
        var book = load()
        book[bucket]?.removeValue(forKey: name)
        save(book)
    }

    static func delete(bucket: String, name: String, at index: Int) {
        var book = load()
        guard var list = book[bucket]?[name], list.indices.contains(index) else { return }
        list.remove(at: index)
        book[bucket, default: [:]][name] = list
        save(book)
    }

    /// 次の回数の初期値＝その学期でのこれまでの最大の回数＋1
    static func nextNumber(bucket: String, name: String) -> Int {
        (entries(bucket: bucket, name: name).map { $0.number }.max() ?? 0) + 1
    }

    /// 今の学期の授業名とフリー録音の名前を、空の記録として入れておく（手で過去の日付を足せるように）
    static func ensureFile(classNames: [String]) {
        var book = load()
        for n in classNames where book[currentSemester]?[n] == nil { book[currentSemester, default: [:]][n] = [] }
        for n in commonNames where book[commonBucket]?[n] == nil { book[commonBucket, default: [:]][n] = [] }
        save(book)
    }

    /// 学期の名前を変えたとき、記録の見出しも付け替える
    static func renameBucket(from old: String, to new: String) {
        guard old != new else { return }
        var book = load()
        guard let records = book.removeValue(forKey: old) else { return }
        book[new, default: [:]].merge(records) { a, b in a + b }
        save(book)
    }
}

// MARK: - 録音のメタ情報（音声ファイルの隣に .json で保存）

struct RecordingMeta: Codable {
    var kind: String        // "講義" / "ゼミ" など
    var name: String        // 授業名
    var number: Int?        // 第何回か
    var period: Int?        // 何限目か
    var multiPeriod: Bool?  // 2コマ続きの授業か
    var bucket: String?     // 出席を数える区分（学期名、または「フリー録音」）
    var start: Date
    var end: Date?

    /// 録音フォルダ（.rec）なら中の meta.json、以前の1ファイル形式（.m4a）なら隣の .json
    static func url(for audio: URL) -> URL {
        audio.pathExtension == "rec"
            ? audio.appendingPathComponent("meta.json")
            : audio.deletingPathExtension().appendingPathExtension("json")
    }

    static func load(for audio: URL) throws -> RecordingMeta {
        let data = try Data(contentsOf: url(for: audio))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMeta.self, from: data)
    }

    func save(for audio: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(self).write(to: RecordingMeta.url(for: audio))
    }
}

// MARK: - 文字起こし

enum TranscribeError: LocalizedError {
    case notAuthorized, unavailable, allChunksFailed
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "音声認識が許可されていません（システム設定 → プライバシーとセキュリティ → 音声認識）"
        case .unavailable: return "日本語の音声認識が使えません"
        case .allChunksFailed: return "音声を認識できませんでした"
        }
    }
}

enum Transcriber {
    static func transcribe(url: URL) async throws -> String {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            do {
                return try await transcribeModern(url: url)
            } catch {
                NSLog("SpeechAnalyzer failed, falling back: \(error)")
            }
        }
        #endif
        return try await transcribeLegacy(url: url)
    }

    #if compiler(>=6.2)
    /// macOS 26 以降：長い音声向けの新しい音声認識（Mac内で完結）
    @available(macOS 26.0, *)
    static func transcribeModern(url: URL) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw TranscribeError.unavailable
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()   // 初回だけ日本語モデルをダウンロード
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)

        let collector = Task { () throws -> String in
            var parts: [String] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            }
            return parts.joined(separator: "\n")
        }

        if let last = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }
    #endif

    /// macOS 25 以前：55秒ずつに区切って音声認識
    static func transcribeLegacy(url: URL) async throws -> String {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscribeError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")), recognizer.isAvailable else {
            throw TranscribeError.unavailable
        }

        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 55)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        var texts: [String] = []
        var failures = 0
        var index = 0
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            try input.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }

            let chunkURL = tmp.appendingPathComponent("chunk\(index).caf")
            try writeChunk(buffer, format: format, to: chunkURL)
            if let text = await recognize(recognizer, url: chunkURL) {
                if !text.isEmpty { texts.append(text) }
            } else {
                failures += 1
            }
            index += 1
        }
        if index > 0 && failures == index { throw TranscribeError.allChunksFailed }
        return texts.joined(separator: "\n")
    }

    private static func writeChunk(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat, to url: URL) throws {
        let out = try AVAudioFile(forWriting: url,
                                  settings: format.settings,
                                  commonFormat: format.commonFormat,
                                  interleaved: format.isInterleaved)
        try out.write(from: buffer)
        // out はこの関数を抜けると閉じられる
    }

    /// 1区間を認識。無音などで認識できなかった場合は空文字、エラーなら nil
    private static func recognize(_ recognizer: SFSpeechRecognizer, url: URL) async -> String? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            var finished = false
            _ = recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let result = result, result.isFinal {
                    finished = true
                    c.resume(returning: result.bestTranscription.formattedString)
                } else if let error = error as NSError? {
                    finished = true
                    // 1110 = 音声が検出されなかった（無音の区間）
                    c.resume(returning: error.code == 1110 ? "" : nil)
                }
            }
        }
    }
}

// MARK: - アプリ本体

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var timetableWindow: NSWindow?
    private var terminateSignal: DispatchSourceSignal?
    private var startPanel: NSPanel?
    private var historyWindow: NSWindow?
    private var config = Config.default

    private var recorder: AVAudioRecorder?
    private var recordingAudio: URL?
    private var recordingMeta: RecordingMeta?
    private var sleepActivity: NSObjectProtocol?
    private var tickTimer: Timer?
    private var segmentTimer: Timer?
    private var partIndex = 0

    private var queue: [URL] = []
    private var processing: URL?
    private var lastError: String?

    // MARK: 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.audioDone, withIntermediateDirectories: true)
        loadConfig()
        cleanupOldAudio()
        Attendance.ensureFile(classNames: config.classes.map { $0.name })

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateTitle()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        installEditMenu()

        // build.sh などで強制終了されたときも、録音をきちんと仕上げてから終了する
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleTerminateSignal() }
        }
        source.resume()
        terminateSignal = source

        // 前回、文字起こし前に終了してしまった録音があれば処理する
        let leftovers = pendingAudioFiles()
        for audio in leftovers { enqueue(audio) }
    }

    /// 終了の合図を受けたら、録音中なら保存してから終了する（文字起こしは次の起動時）
    private func handleTerminateSignal() {
        if recorder != nil { stopRecording(process: false) }
        exit(0)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder != nil || processing != nil {
            let alert = NSAlert()
            alert.messageText = recorder != nil ? "録音中です" : "文字起こし中です"
            alert.informativeText = "終了すると録音・文字起こしが中断されます（音声は残り、次回起動時に文字起こしします）。終了しますか？"
            alert.addButton(withTitle: "終了しない")
            alert.addButton(withTitle: "終了する")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            if recorder != nil { stopRecording(process: false) }
        }
        return .terminateNow
    }

    // MARK: 設定

    private func loadConfig() {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: Paths.config),
           let loaded = try? JSONDecoder().decode(Config.self, from: data) {
            config = loaded
        } else if !fm.fileExists(atPath: Paths.config.path) {
            saveConfig()
        } else {
            lastError = "config.json の書き方に誤りがあります"
        }
        syncAttendanceContext()
    }

    /// 出席の数え方（今の学期・フリー録音の名前）を設定に合わせる
    private func syncAttendanceContext() {
        Attendance.currentSemester = config.currentSemester
        Attendance.commonNames = Set(config.otherKinds)
    }

    private func saveConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(config) { try? data.write(to: Paths.config) }
    }

    private func outputRoot() -> URL? {
        if let custom = config.outputFolder, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        // パソコン版のGoogleドライブがあればマイドライブに、なければ「書類」フォルダに保存
        if let drive = Paths.googleDriveRoot() {
            return drive.appendingPathComponent("LectureRecorder", isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("LectureRecorder", isDirectory: true)
    }

    // MARK: 時間割から今の授業を探す

    private static let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    private func todaySymbol(_ date: Date = Date()) -> String {
        let w = Calendar.current.component(.weekday, from: date)   // 1 = 日曜
        return Self.weekdaySymbols[w - 1]
    }

    private func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        return h * 60 + m
    }

    /// 今の時刻に当てはまる授業と時限。
    /// 授業中のコマ → これから始まるコマ（開始20分前から）→ 終わったばかりのコマ（終了15分後まで）の順で選ぶ
    private func currentSlot(for onlyName: String? = nil) -> (entry: ClassEntry, period: Int)? {
        let now = Date()
        let cal = Calendar.current
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let today = todaySymbol(now)

        var inside: (ClassEntry, Int)?
        var upcoming: (ClassEntry, Int, Int)?   // 開始時刻が一番早いもの
        var ended: (ClassEntry, Int, Int)?      // 終了時刻が一番遅いもの
        for entry in config.classes where entry.day == today && (onlyName == nil || entry.name == onlyName) {
            for period in entry.periods ?? [] {
                guard let range = config.periods[String(period)] else { continue }
                let parts = range.split(separator: "-").map(String.init)
                guard parts.count == 2, let s = minutes(parts[0]), let e = minutes(parts[1]) else { continue }
                if nowMin >= s && nowMin <= e {
                    inside = (entry, period)
                } else if nowMin < s && nowMin >= s - 20 {
                    if upcoming == nil || s < upcoming!.2 { upcoming = (entry, period, s) }
                } else if nowMin > e && nowMin <= e + 15 {
                    if ended == nil || e > ended!.2 { ended = (entry, period, e) }
                }
            }
        }
        if let i = inside { return (i.0, i.1) }
        if let u = upcoming { return (u.0, u.1) }
        if let d = ended { return (d.0, d.1) }
        return nil
    }

    private func currentClass() -> ClassEntry? { currentSlot()?.entry }

    private func classEntry(named name: String) -> ClassEntry? {
        config.classes.first { $0.name == name }
    }

    /// 今が何限目か（時間外なら、その授業の最初のコマ）
    private func periodForRecording(name: String) -> Int? {
        guard let entry = classEntry(named: name), let periods = entry.periods, !periods.isEmpty else { return nil }
        return currentSlot(for: name)?.period ?? periods.first
    }

    // MARK: メニュー

    func menuWillOpen(_ menu: NSMenu) {
        loadConfig()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let err = lastError {
            let e = NSMenuItem(title: "⚠️ " + err, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(.separator())

        if recordingMeta != nil {
            menu.addItem(item("■ 録音を終了して文字起こし", #selector(stopTapped)))

            menu.addItem(item("録音中の情報を変更…", #selector(openEditPanelTapped)))
        } else {
            menu.addItem(item("● 講義の録音を開始…", #selector(openStartPanelTapped)))
            menu.addItem(item("● フリー録音を開始…", #selector(openOtherStartPanelTapped)))
        }

        let pending = pendingAudioFiles().filter { $0 != recordingAudio && $0 != processing && !queue.contains($0) }
        if !pending.isEmpty {
            menu.addItem(item("未完了の録音を文字起こし（\(pending.count)件）", #selector(retryTapped)))
        }

        // 画面を開くもの
        menu.addItem(.separator())
        menu.addItem(item("出席履歴…", #selector(openHistoryTapped)))
        menu.addItem(item("時間割を編集…", #selector(editTimetableTapped)))

        // フォルダ・ファイルを開くもの
        menu.addItem(.separator())
        menu.addItem(item("保存先フォルダを開く", #selector(openOutputTapped)))
        menu.addItem(item("詳細設定ファイルを開く…", #selector(editConfigTapped)))
        let login = item("ログイン時に起動", #selector(toggleLoginTapped))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("LectureRecorderを終了", #selector(quitTapped)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func statusText() -> String {
        if let meta = recordingMeta {
            return "録音中：\(meta.name) #\(meta.number ?? 1)（\(elapsed(since: meta.start))）"
        }
        if let p = processing, let meta = try? RecordingMeta.load(for: p) {
            let more = queue.isEmpty ? "" : "／ほか\(queue.count)件待ち"
            return "文字起こし中：\(meta.name)\(more)"
        }
        return "待機中"
    }

    private func elapsed(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        if let meta = recordingMeta {
            button.title = "● \(elapsed(since: meta.start))"
            button.image = nil
        } else if processing != nil {
            button.title = "文字起こし中…"
            button.image = nil
        } else {
            button.title = ""
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "LectureRecorder")
        }
    }

    // MARK: 操作

    @objc private func startClassTapped(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        requestMicThenRecord(kind: "講義", name: name)
    }

    @objc private func startOtherTapped(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        requestMicThenRecord(kind: kind, name: kind)
    }

    @objc private func stopTapped() { stopRecording(process: true) }


    /// 録音を止めて、音声ごと消す（確認は画面側で済ませている）
    private func discardRecording() {
        guard let audio = recordingAudio else { return }
        stopRecording(process: false, countAttendance: false)
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: RecordingMeta.url(for: audio))
    }

    @objc private func retryTapped() {
        let targets = pendingAudioFiles()
            .filter { $0 != recordingAudio && $0 != processing && !queue.contains($0) }
        for audio in targets { enqueue(audio) }
    }

    @objc private func openOutputTapped() {
        guard let root = outputRoot() else {
            showAlert("Googleドライブが見つかりません", "パソコン版のGoogleドライブを入れてログインしてください。")
            return
        }
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    @objc private func editConfigTapped() {
        if !FileManager.default.fileExists(atPath: Paths.config.path) { saveConfig() }
        openInTextEdit(Paths.config)
    }

    @objc private func editTimetableTapped() {
        if let w = timetableWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        loadConfig()
        let model = TimetableModel(config: config)
        let view = TimetableView(
            model: model,
            onSave: { [weak self] in
                guard let self = self else { return }
                model.apply(to: &self.config)
                self.saveConfig()
                self.syncAttendanceContext()
                Attendance.ensureFile(classNames: self.config.classes.map { $0.name })
                self.timetableWindow?.close()
            },
            onCancel: { [weak self] in
                self?.timetableWindow?.close()
            }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]   // 中身に合わせてウィンドウの高さを変える
        let w = NSWindow(contentViewController: hosting)
        w.title = "時間割の編集"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        timetableWindow = w
        present(w)
    }

    /// 中身の大きさに合わせてから画面の中央に出す（Dockには出さない）
    private func present(_ w: NSWindow) {
        if let view = w.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            w.setContentSize(view.fittingSize)
        }
        w.center()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // 表示後に大きさが確定してから、もう一度中央に合わせる
        DispatchQueue.main.async { w.center() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if w === timetableWindow { timetableWindow = nil }
        if w === startPanel { startPanel = nil }
        if w === historyWindow { historyWindow = nil }
    }

    // MARK: 講義の録音開始（確認画面）

    @objc private func openEditPanelTapped() {
        guard let meta = recordingMeta else { return }
        startPanel?.close()
        startPanel = nil
        loadConfig()
        let mode: StartMode = meta.kind == "講義" ? .lecture : .other
        let model = StartPanelModel(config: config, mode: mode, defaultName: meta.name,
                                    defaultPeriod: meta.period, initialNumber: meta.number,
                                    editingStart: meta.start)
        let view = StartPanelView(
            model: model,
            onStart: { [weak self] name, period, number in
                guard let self = self else { return }
                self.startPanel?.close()
                self.applyRecordingEdit(name: name, period: period, number: number, mode: mode)
            },
            onCancel: { [weak self] in self?.startPanel?.close() },
            onDiscard: { [weak self] in
                guard let self = self else { return }
                self.startPanel?.close()
                self.discardRecording()
            }
        )
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.title = model.title
        panel.styleMask = [.titled]
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self
        startPanel = panel
        present(panel)
    }

    /// 録音中に授業・時限・回数を変更する
    private func applyRecordingEdit(name: String, period: Int?, number: Int, mode: StartMode) {
        guard var meta = recordingMeta, let audio = recordingAudio else { return }
        meta.name = name
        meta.kind = mode == .lecture ? "講義" : name
        meta.number = number
        meta.period = mode == .lecture ? period : nil
        meta.multiPeriod = mode == .lecture ? ((classEntry(named: name)?.periods?.count ?? 0) > 1) : nil
        meta.bucket = Attendance.bucket(for: name)
        recordingMeta = meta
        try? meta.save(for: audio)
    }

    @objc private func openStartPanelTapped() { openStartPanel(mode: .lecture) }
    @objc private func openOtherStartPanelTapped() { openStartPanel(mode: .other) }

    private func openStartPanel(mode: StartMode) {
        guard recorder == nil else { return }
        startPanel?.close()   // もう一方の確認画面が開いていたら閉じる
        startPanel = nil
        loadConfig()
        let slot = currentSlot()
        let model = StartPanelModel(config: config, mode: mode,
                                    defaultName: mode == .lecture ? slot?.entry.name : nil,
                                    defaultPeriod: mode == .lecture ? slot?.period : nil)
        let view = StartPanelView(
            model: model,
            onStart: { [weak self] name, period, number in
                guard let self = self else { return }
                self.startPanel?.close()
                self.requestMicThenRecord(kind: mode == .lecture ? "講義" : name,
                                          name: name, number: number, period: period)
            },
            onCancel: { [weak self] in
                self?.startPanel?.close()
            }
        )
        // ×ボタンなし（キャンセルで閉じる）。ウィンドウを閉じるとアプリを終了するツールを使っていても安全なように
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.title = model.title
        panel.styleMask = [.titled]
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self
        startPanel = panel
        present(panel)
    }

    // MARK: 出席履歴

    @objc private func openHistoryTapped() {
        if let w = historyWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        loadConfig()
        Attendance.ensureFile(classNames: config.classes.map { $0.name })
        let view = HistoryView(model: HistoryModel(config: config))
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "出席履歴"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        historyWindow = w
        present(w)
    }

    /// メニューバー常駐アプリでも ⌘C / ⌘V / ⌘A / ⌘Z / ⌘W が文字入力欄で使えるようにする
    private func installEditMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "ウインドウを閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func editAttendanceTapped() {
        Attendance.ensureFile(classNames: config.classes.map { $0.name })
        openInTextEdit(Attendance.url)
    }

    private func openInTextEdit(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-e", url.path]
        try? p.run()
    }

    @objc private func toggleLoginTapped() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("ログイン項目を変更できませんでした", error.localizedDescription)
        }
    }

    @objc private func quitTapped() { NSApp.terminate(nil) }

    // MARK: 録音

    private func requestMicThenRecord(kind: String, name: String, number: Int? = nil, period: Int? = nil) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording(kind: kind, name: name, number: number, period: period)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.startRecording(kind: kind, name: name, number: number, period: period) }
                    else { self.showMicDenied() }
                }
            }
        default:
            showMicDenied()
        }
    }

    private func showMicDenied() {
        showAlert("マイクが許可されていません",
                  "システム設定 → プライバシーとセキュリティ → マイク で「LectureRecorder」をオンにしてください。")
    }

    /// 録音を区切る間隔（電源が急に落ちても、失うのは最後の区切りの分だけ）
    private static let segmentSeconds: TimeInterval = 300

    private static let recordSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    private func partURL(_ session: URL, _ index: Int) -> URL {
        session.appendingPathComponent(String(format: "part%03d.m4a", index))
    }

    private func makeRecorder(_ url: URL) throws -> AVAudioRecorder {
        let r = try AVAudioRecorder(url: url, settings: Self.recordSettings)
        guard r.record() else {
            throw NSError(domain: "LectureRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "録音を開始できませんでした"])
        }
        return r
    }

    private func startRecording(kind: String, name: String, number: Int? = nil, period: Int? = nil) {
        guard recorder == nil else { return }
        let start = Date()
        // 録音1回分を1つのフォルダにまとめ、その中に5分ごとのファイルを作る
        let session = Paths.audio.appendingPathComponent(fileBase(start: start, name: name) + ".rec", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let bucket = Attendance.bucket(for: name)
            let isLecture = kind == "講義"
            let meta = RecordingMeta(kind: kind, name: name,
                                     number: number ?? Attendance.nextNumber(bucket: bucket, name: name),
                                     period: isLecture ? (period ?? periodForRecording(name: name)) : nil,
                                     multiPeriod: isLecture ? ((classEntry(named: name)?.periods?.count ?? 0) > 1) : nil,
                                     bucket: bucket,
                                     start: start, end: nil)
            try meta.save(for: session)
            recorder = try makeRecorder(partURL(session, 1))
            partIndex = 1
            recordingAudio = session
            recordingMeta = meta
            lastError = nil
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "講義を録音中")
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateTitle() }
            }
            segmentTimer = Timer.scheduledTimer(withTimeInterval: Self.segmentSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rotateSegment() }
            }
            updateTitle()
        } catch {
            try? FileManager.default.removeItem(at: session)
            showAlert("録音を開始できませんでした", error.localizedDescription)
        }
    }

    /// 次のファイルの録音を始めてから前のファイルを止める（途切れを作らないため）
    private func rotateSegment() {
        guard let old = recorder, let session = recordingAudio else { return }
        let next = partIndex + 1
        do {
            let r = try makeRecorder(partURL(session, next))
            old.stop()
            recorder = r
            partIndex = next
        } catch {
            NSLog("録音の区切りに失敗（今のファイルで録音を続けます）: \(error)")
        }
    }

    private func stopRecording(process: Bool, countAttendance: Bool = true) {
        guard let r = recorder, let audio = recordingAudio, var meta = recordingMeta else { return }
        r.stop()
        meta.end = Date()
        try? meta.save(for: audio)
        if countAttendance {
            let bucket = meta.bucket ?? Attendance.bucket(for: meta.name)
            Attendance.record(bucket: bucket, name: meta.name, date: meta.start,
                              number: meta.number ?? Attendance.nextNumber(bucket: bucket, name: meta.name),
                              period: meta.period)
        }
        recorder = nil
        recordingAudio = nil
        recordingMeta = nil
        tickTimer?.invalidate()
        tickTimer = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
        updateTitle()
        if process { enqueue(audio) }
    }

    private func fileBase(start: Date, name: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let safe = name.replacingOccurrences(of: "/", with: "・").replacingOccurrences(of: ":", with: "：")
        return "\(f.string(from: start))_\(safe)"
    }

    // MARK: 文字起こしの順番待ち

    private func pendingAudioFiles() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Paths.audio, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "rec" || $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func enqueue(_ audio: URL) {
        guard audio != processing, !queue.contains(audio) else { return }
        queue.append(audio)
        if processing == nil { processNext() }
    }

    private func processNext() {
        guard !queue.isEmpty else {
            processing = nil
            updateTitle()
            return
        }
        let audio = queue.removeFirst()
        processing = audio
        updateTitle()

        Task {
            var recordingName: String?
            do {
                var meta = try RecordingMeta.load(for: audio)
                recordingName = meta.name
                if meta.end == nil {   // 途中で終了した録音
                    meta.end = self.latestModification(of: audio) ?? meta.start
                    let bucket = meta.bucket ?? Attendance.bucket(for: meta.name)
                    if meta.number == nil { meta.number = Attendance.nextNumber(bucket: bucket, name: meta.name) }
                    Attendance.record(bucket: bucket, name: meta.name, date: meta.start,
                                      number: meta.number ?? 1, period: meta.period)
                }
                // 5分ごとのファイルのうち、読めるものだけを順番に文字起こしする
                // （電源が急に落ちたときなど、最後のファイルが壊れていることがある）
                let parts = self.audioParts(of: audio)
                let readable = parts.filter { (try? AVAudioFile(forReading: $0)) != nil }
                if readable.isEmpty {
                    self.moveToBroken(audio)
                    self.lastError = "録音が壊れていました：\(meta.name)"
                    self.notify("録音を読み込めませんでした：\(meta.name)",
                                "録音中にアプリが強制終了されたなどの理由で、音声ファイルが壊れていました。")
                    self.processNext()
                    return
                }
                var texts: [String] = []
                for part in readable {
                    let t = try await Transcriber.transcribe(url: part)
                    if !t.isEmpty { texts.append(t) }
                }
                var text = texts.joined(separator: "\n")
                if readable.count < parts.count {
                    text += "\n\n（録音の一部（約\((parts.count - readable.count) * 5)分）を読み込めなかったため、その部分は含まれていません）"
                }
                try self.writeTranscript(meta: meta, text: text, audio: audio)
                self.moveToDone(audio)
                self.lastError = nil
                self.notify("文字起こし完了：\(meta.name)",
                            "保存先フォルダに保存しました。")
            } catch {
                self.lastError = recordingName.map { "文字起こしに失敗しました：\($0)" } ?? "文字起こしに失敗しました"
                self.notify("文字起こしに失敗しました",
                            "\(error.localizedDescription)\nメニューの「未完了の録音を文字起こし」で再試行できます。")
            }
            self.processNext()
        }
    }

    private func writeTranscript(meta: RecordingMeta, text: String, audio: URL) throws {
        guard let root = outputRoot() else {
            throw NSError(domain: "LectureRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Googleドライブが見つかりません"])
        }
        let folder = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let d = DateFormatter()
        d.locale = Locale(identifier: "ja_JP")
        d.dateFormat = "yyyy/MM/dd"
        let t = DateFormatter()
        t.locale = Locale(identifier: "ja_JP")
        t.dateFormat = "HH:mm"
        let end = meta.end ?? meta.start
        let mins = max(1, Int(end.timeIntervalSince(meta.start) / 60))

        let body = text.isEmpty ? "（音声を認識できませんでした）" : text
        let number = meta.number.map { "#\($0)" } ?? "不明"
        let periodLine = meta.period.map { "時限: \($0)限\(meta.multiPeriod == true ? "（2コマ続き）" : "")\n" } ?? ""
        let semesterLine = (meta.kind == "講義" && meta.bucket != nil) ? "学期: \(meta.bucket!)\n" : ""
        let content = """
        ---
        種別: \(meta.kind)
        \(semesterLine)授業: \(meta.name)
        回数: \(number)
        \(periodLine)日付: \(d.string(from: meta.start))（\(todaySymbol(meta.start))）
        録音: \(t.string(from: meta.start))〜\(t.string(from: end))（\(mins)分）
        ---

        \(body)

        """
        let file = folder.appendingPathComponent(fileBase(start: meta.start, name: meta.name) + ".txt")
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    private func moveToDone(_ audio: URL) {
        let fm = FileManager.default
        // 録音フォルダはメタ情報ごと移す。以前の形式は音声と .json を別々に移す
        let sources = audio.pathExtension == "rec" ? [audio] : [audio, RecordingMeta.url(for: audio)]
        for src in sources {
            let dst = Paths.audioDone.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
    }

    /// 録音フォルダ（.rec）なら中の5分ごとのファイル、以前の形式ならそのファイル自体
    private func audioParts(of audio: URL) -> [URL] {
        guard audio.pathExtension == "rec" else { return [audio] }
        let items = (try? FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 録音の最後のファイルの更新時刻（＝録音が終わったおおよその時刻）
    private func latestModification(of audio: URL) -> Date? {
        audioParts(of: audio)
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }

    private func moveToBroken(_ audio: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.audioBroken, withIntermediateDirectories: true)
        // 録音フォルダはメタ情報ごと移す。以前の形式は音声と .json を別々に移す
        let sources = audio.pathExtension == "rec" ? [audio] : [audio, RecordingMeta.url(for: audio)]
        for src in sources {
            let dst = Paths.audioBroken.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
    }

    private func cleanupOldAudio() {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-Double(max(1, config.keepAudioDays)) * 86_400)
        let items = (try? fm.contentsOfDirectory(at: Paths.audioDone, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date = date, date < limit { try? fm.removeItem(at: url) }
        }
    }

    // MARK: 通知・ダイアログ

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - エントリーポイント

@main
struct LectureRecorderMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
