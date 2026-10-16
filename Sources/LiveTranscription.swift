// 録音しながらの文字起こし（MixRec と同じ仕組み）
//
// ・マイクの音は Core Audio から直接受け取る（AVAudioEngine は出力側まで準備するため、
//   イヤホン接続時などに数十秒かかることがある）。内蔵マイクがあれば内蔵マイクを使う
// ・macOS 26 以降は SpeechAnalyzer（長い講義向け・沈黙で止まらない）、それより前は SFSpeechRecognizer
// ・日英混在の授業は、日本語と英語の2つで同時に認識し、区間ごとに確からしい方を選ぶ
// ・確定した行は録音フォルダの live.txt に少しずつ書き足す（アプリが落ちても残る）

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Speech

// MARK: - 動作の記録（~/Library/Logs/LectureRecorder.log）

enum Log {
    private static let lock = NSLock()
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LectureRecorder.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - 文字起こしの1区間

struct TranscriptPiece: Sendable {
    var time: TimeInterval        // 録音開始からの秒数
    var end: TimeInterval
    var text: String
    var confidence: Double?       // 0〜1（分からなければ nil）
    var lang: String              // "ja-JP" / "en-US"

    var isEnglish: Bool { lang.hasPrefix("en") }

    /// 保存する1行（[00:12:34] 本文）
    func line(offset: TimeInterval = 0) -> String {
        let s = max(0, Int(time + offset))
        return String(format: "[%02d:%02d:%02d] ", s / 3600, s / 60 % 60, s % 60) + text
    }
}

/// 日英混在のとき、同じ区間の日本語の認識と英語の認識のうち、確からしい方を選ぶ
enum LanguageMerger {
    /// カタカナの割合（英語の話を日本語で認識すると、カタカナだらけになりやすい）
    static func katakanaRatio(_ s: String) -> Double {
        var kana = 0, total = 0
        for u in s.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u) && !CharacterSet.punctuationCharacters.contains(u) {
            total += 1
            if (0x30A0...0x30FF).contains(u.value) { kana += 1 }
        }
        return total == 0 ? 0 : Double(kana) / Double(total)
    }

    static func score(_ pieces: [TranscriptPiece]) -> Double {
        var sum = 0.0, weight = 0.0
        for p in pieces {
            let n = Double(max(1, p.text.count))
            sum += (p.confidence ?? 0.5) * n
            weight += n
        }
        var s = weight > 0 ? sum / weight : 0
        if let first = pieces.first, !first.isEnglish {
            let text = pieces.map(\.text).joined()
            if katakanaRatio(text) > 0.5 { s -= 0.15 }
        }
        return s
    }

    /// 重なっている区間のまとまりから、片方の言語の分だけを返す
    static func choose(_ cluster: [TranscriptPiece]) -> [TranscriptPiece] {
        let ja = cluster.filter { !$0.isEnglish }
        let en = cluster.filter { $0.isEnglish }
        if ja.isEmpty { return en.sorted { $0.time < $1.time } }
        if en.isEmpty { return ja.sorted { $0.time < $1.time } }
        let pick = score(en) > score(ja) ? en : ja
        return pick.sorted { $0.time < $1.time }
    }

    /// 時間が重なる区間をまとめる（長くなりすぎないよう30秒で切る）
    static func clusters(_ pieces: [TranscriptPiece]) -> [[TranscriptPiece]] {
        let sorted = pieces.sorted { $0.time < $1.time }
        var result: [[TranscriptPiece]] = []
        var i = 0
        while i < sorted.count {
            var cluster = [sorted[i]]
            var end = sorted[i].end
            var j = i + 1
            while j < sorted.count, sorted[j].time < end + 0.3, end - sorted[i].time < 30 {
                cluster.append(sorted[j])
                end = max(end, sorted[j].end)
                j += 1
            }
            result.append(cluster)
            i = j
        }
        return result
    }

    static func merge(_ a: [TranscriptPiece], _ b: [TranscriptPiece]) -> [TranscriptPiece] {
        clusters(a + b).flatMap { choose($0) }
    }
}

// MARK: - マイク（Core Audio から直接受け取る）

enum CaptureError: LocalizedError {
    case coreAudio(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let text, let status): return "\(text)（エラー \(status)）"
        case .message(let text): return text
        }
    }
}

enum CoreAudioHelper {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        guard err == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return err == noErr ? value : nil
    }

    static func allDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// 内蔵マイク（教室では机の上のMacの方が、AirPodsのマイクより先生の声をよく拾う）
    static func builtInInputDevice() -> AudioDeviceID? {
        allDevices().first { id in
            inputChannelCount(id) > 0 && uint32Property(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
        }
    }
}

/// マイクの音を受け取って onBuffer に渡すだけ（録音ファイルは AVAudioRecorder が別に作る）
final class MicTap: @unchecked Sendable {
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "lecturerecorder.mic", qos: .userInitiated)
    /// 音が届くたびに呼ばれる。start の前に設定する
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var deviceName = ""

    func start() throws {
        guard let device = CoreAudioHelper.builtInInputDevice() ?? CoreAudioHelper.defaultInputDevice() else {
            throw CaptureError.message("マイクが見つかりません")
        }
        deviceName = CoreAudioHelper.stringProperty(device, kAudioObjectPropertyName) ?? "?"

        var addr = CoreAudioHelper.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        guard err == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            throw CaptureError.coreAudio("マイクの情報を読み取れませんでした", err)
        }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams)
        guard err == noErr, let stream = streams.first else {
            throw CaptureError.coreAudio("マイクの情報を読み取れませんでした", err)
        }

        var fmtAddr = CoreAudioHelper.address(kAudioStreamPropertyVirtualFormat)
        var asbd = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(stream, &fmtAddr, 0, nil, &fmtSize, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.coreAudio("マイクの音の形式を読み取れませんでした", err)
        }

        let handler = onBuffer
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, inputData, _, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard list.count > 0 else { return }
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: list[0])   // 1本目のストリームだけ使う
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &single, deallocator: nil) else { return }
            handler?(buffer)
        }
        guard err == noErr, let procID else {
            throw CaptureError.coreAudio("マイクの受け取りを準備できませんでした", err)
        }
        err = AudioDeviceStart(device, procID)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            throw CaptureError.coreAudio("マイクを開始できませんでした", err)
        }
        deviceID = device
        ioProcID = procID
    }

    func stop() {
        if let ioProcID, deviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
        deviceID = AudioDeviceID(kAudioObjectUnknown)
        queue.sync {}
    }
}

/// 音声の形式を変える（音声スレッドだけで使う）
final class BufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

// MARK: - 文字起こし（新旧共通の形）

protocol LiveTranscribing: AnyObject, Sendable {
    var language: String { get }
    var onPartial: ((String) -> Void)? { get set }          // 認識途中の文字（"" で消す）
    var onFinal: ((TranscriptPiece) -> Void)? { get set }   // 確定した1区間
    var onStatus: ((String?) -> Void)? { get set }          // お知らせ（ダウンロード中など）
    func start(recordingStart: Date)
    func append(_ buffer: AVAudioPCMBuffer)
    func stop()   // 最後の確定を待つので、画面のスレッド以外から呼ぶ
}

enum LiveTranscriberFactory {
    static func make(language: String) -> LiveTranscribing {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return ModernLiveTranscriber(language: language) }
        #endif
        return LegacyLiveTranscriber(language: language)
    }

    static var engineName: String {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return "SpeechAnalyzer" }
        #endif
        return "SFSpeechRecognizer"
    }
}

/// macOS 26 より前：Apple の音声認識で、話の区切り（約3秒変化なし）か約50秒ごとに区切る
final class LegacyLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    let language: String
    var onPartial: ((String) -> Void)?
    var onFinal: ((TranscriptPiece) -> Void)?
    var onStatus: ((String?) -> Void)?

    private struct Segment {
        let offset: TimeInterval
        var text: String = ""
        var confidence: Double?
        var task: SFSpeechRecognitionTask?
    }

    private let recognizer: SFSpeechRecognizer?
    private let queue = DispatchQueue(label: "lecturerecorder.transcribe")
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private let converter = BufferConverter()           // 音声スレッドだけが触る
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var segments: [Int: Segment] = [:]
    private var currentID = 0
    private var requestStarted = Date()
    private var lastChange = Date()
    private var recordingStart = Date()
    private var timer: DispatchSourceTimer?
    private var running = false
    private var failures = 0

    private let silenceToSplit: TimeInterval = 3.0
    private let maxSegment: TimeInterval = 50
    private let finalTimeout: TimeInterval = 5

    init(language: String) {
        self.language = language
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
    }

    func start(recordingStart: Date) {
        queue.async {
            guard let recognizer = self.recognizer else {
                Log.write("[\(self.language)] 音声認識が使えません")
                self.onStatus?("この言語の音声認識が使えません")
                return
            }
            Log.write("[\(self.language)] 録音中の文字起こし開始（旧方式、Mac内: \(recognizer.supportsOnDeviceRecognition)）")
            if !recognizer.supportsOnDeviceRecognition {
                self.onStatus?("Mac内の音声認識が使えないため、ネット経由で認識しています（止まることがあります）")
            }
            self.running = true
            self.failures = 0
            self.recordingStart = recordingStart
            self.startRequest()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.checkSplit() }
            t.resume()
            self.timer = t
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer, to: targetFormat) else { return }
        queue.async { self.request?.append(converted) }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            request?.endAudio()
            request = nil
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if queue.sync(execute: { segments.isEmpty }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        queue.sync {
            for id in segments.keys.sorted() { finalize(id) }
            onPartial?("")
        }
    }

    private func startRequest() {
        guard running, let recognizer else { return }
        currentID += 1
        let id = currentID
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        requestStarted = Date()
        lastChange = Date()
        var segment = Segment(offset: Date().timeIntervalSince(recordingStart))
        segment.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async { self.handle(id: id, result: result, error: error) }
        }
        segments[id] = segment
    }

    private func handle(id: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        guard segments[id] != nil else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            failures = 0
            if !text.isEmpty, text != segments[id]?.text {   // 空の確定で上書きしない
                segments[id]?.text = text
                if id == currentID {
                    lastChange = Date()
                    onPartial?(text)
                }
            }
            if result.isFinal {
                let cs = result.bestTranscription.segments.map { Double($0.confidence) }.filter { $0 > 0 }
                if !cs.isEmpty { segments[id]?.confidence = cs.reduce(0, +) / Double(cs.count) }
                finalize(id)
                if id == currentID { restartAfterEnd() }
            }
        } else if let error {
            let ns = error as NSError
            // 1110 =「声が検出されない」。黙っている間に終わっただけなので失敗扱いしない
            let isSilence = ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110
            if !isSilence {
                Log.write("[\(language)] 認識エラー: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
                if id == currentID { failures += 1 }
            }
            finalize(id)
            if id == currentID { restartAfterEnd() }
        }
    }

    private func restartAfterEnd() {
        request = nil
        onPartial?("")
        let delay = failures == 0 ? 0.1 : min(30, pow(2, Double(failures)))   // エラーが続くときは間隔を広げる
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.request == nil else { return }
            self.startRequest()
        }
    }

    private func checkSplit() {
        guard running, request != nil, let current = segments[currentID] else { return }
        let now = Date()
        let age = now.timeIntervalSince(requestStarted)
        if !current.text.isEmpty, now.timeIntervalSince(lastChange) > silenceToSplit || age > maxSegment {
            split()
        } else if current.text.isEmpty, age > maxSegment {
            split()   // 無音のまま長く続くと止まるので作り直す
        }
    }

    private func split() {
        let endingID = currentID
        request?.endAudio()
        onPartial?("")
        startRequest()
        queue.asyncAfter(deadline: .now() + finalTimeout) { [weak self] in
            self?.finalize(endingID)   // 確定結果が来なかった場合の保険
        }
    }

    private func finalize(_ id: Int) {
        guard let segment = segments.removeValue(forKey: id) else { return }
        segment.task?.finish()
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let end = Date().timeIntervalSince(recordingStart)
        onFinal?(TranscriptPiece(time: segment.offset, end: max(segment.offset, end), text: text,
                                 confidence: segment.confidence, lang: language))
    }
}

#if compiler(>=6.2)
/// 文字列の確からしさ（文字数で重みをつけた平均）
@available(macOS 26.0, *)
func transcriptionConfidence(of text: AttributedString) -> Double? {
    var sum = 0.0, weight = 0.0
    for run in text.runs {
        guard let c = run.transcriptionConfidence else { continue }
        let n = Double(max(1, text[run.range].characters.count))
        sum += c * n
        weight += n
    }
    return weight > 0 ? sum / weight : nil
}

/// macOS 26 以降：SpeechAnalyzer（長い講義向け。沈黙で止まらず、Mac内で処理する）
@available(macOS 26.0, *)
final class ModernLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    let language: String
    var onPartial: ((String) -> Void)?
    var onFinal: ((TranscriptPiece) -> Void)?
    var onStatus: ((String?) -> Void)?

    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?   // 準備ができるまでは nil（その間の音は捨てる）
    private var startOffset: TimeInterval?     // 録音開始から、最初の音を渡すまでの秒数
    private var recordingStart = Date()
    private var analyzer: SpeechAnalyzer?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private let converter = BufferConverter()  // 音声スレッドだけが触る

    init(language: String) {
        self.language = language
    }

    func start(recordingStart: Date) {
        self.recordingStart = recordingStart
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        lock.withLock { continuation = cont }
        let language = self.language

        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
                    Log.write("[\(language)] このMacではこの言語の文字起こしが使えません")
                    self.onStatus?("このMacではこの言語の文字起こしが使えません")
                    return
                }
                let transcriber = SpeechTranscriber(locale: locale,
                                                    transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults, .fastResults],
                                                    attributeOptions: [.audioTimeRange, .transcriptionConfidence])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    Log.write("[\(language)] 文字起こしデータをダウンロード中")
                    self.onStatus?("文字起こし用のデータをダウンロード中…（初回のみ）")
                    try await request.downloadAndInstall()
                    self.onStatus?(nil)
                }
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                let analyzer = SpeechAnalyzer(modules: [transcriber])

                let results = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard let self else { return }
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            if result.isFinal {
                                guard !text.isEmpty else { self.onPartial?(""); continue }
                                let offset = self.lock.withLock { self.startOffset } ?? 0
                                let s = result.range.start.seconds
                                let e = result.range.end.seconds
                                let start = offset + (s.isFinite ? s : 0)
                                let end = offset + (e.isFinite ? e : (s.isFinite ? s : 0))
                                self.onFinal?(TranscriptPiece(time: start, end: max(start, end), text: text,
                                                              confidence: transcriptionConfidence(of: result.text),
                                                              lang: language))
                            } else {
                                self.onPartial?(text)
                            }
                        }
                    } catch {
                        Log.write("[\(language)] 文字起こしエラー: \(error.localizedDescription)")
                    }
                }

                try await analyzer.start(inputSequence: stream)
                self.lock.withLock {
                    self.analyzer = analyzer
                    self.resultsTask = results
                    self.targetFormat = format
                }
                Log.write("[\(language)] 録音中の文字起こし開始（SpeechAnalyzer、\(Int(format?.sampleRate ?? 0))Hz）")
            } catch {
                Log.write("[\(language)] 文字起こしを開始できませんでした: \(error.localizedDescription)")
                self.onStatus?("文字起こしを開始できませんでした：\(error.localizedDescription)")
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let format = targetFormat
        let cont = continuation
        if format != nil, startOffset == nil {
            startOffset = Date().timeIntervalSince(recordingStart)
        }
        lock.unlock()
        guard let format, let cont, let converted = converter.convert(buffer, to: format) else { return }
        cont.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        let cont: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            targetFormat = nil
            let c = continuation
            continuation = nil
            return c
        }
        cont?.finish()

        let done = DispatchSemaphore(value: 0)
        let setup = setupTask
        Task { [weak self] in
            await setup?.value
            guard let self else { done.signal(); return }
            let (analyzer, results) = self.lock.withLock { (self.analyzer, self.resultsTask) }
            if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            await results?.value
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            let analyzer = lock.withLock { self.analyzer }
            Task { await analyzer?.cancelAndFinishNow() }
            setupTask?.cancel()
        }
        onPartial?("")
    }
}
#endif

// MARK: - 録音1回分の文字起こし（マイク／Macの音 → 認識 → 字幕・live.txt）

/// 音声のスレッドから、今動いている文字起こしすべてに音を渡す
final class BufferFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [LiveTranscribing] = []

    func set(_ t: [LiveTranscribing]) {
        lock.lock(); targets = t; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let t = targets; lock.unlock()
        t.forEach { $0.append(buffer) }
    }
}

@MainActor
final class LiveSession {
    let model: LiveCaptionModel
    private let options: LiveCaptionOptions
    private let fileURL: URL
    private let recordingStart: Date
    private let mic = MicTap()
    private let workQueue = DispatchQueue(label: "lecturerecorder.live", qos: .userInitiated)
    private var transcribers: [LiveTranscribing] = []
    private var pending: [(piece: TranscriptPiece, arrived: Date)] = []   // 日英混在：選ぶ前の区間
    private var partials: [String: (text: String, at: Date)] = [:]
    private var timer: Timer?
    private var finished = false
    /// 文字起こしに渡す音の入口（Macの音を録るときは、そちらからも渡される）
    nonisolated let fanout = BufferFanout()

    nonisolated static let fileName = "live.txt"

    init(options: LiveCaptionOptions, folder: URL, recordingStart: Date, model: LiveCaptionModel) {
        self.options = options
        self.model = model
        self.recordingStart = recordingStart
        fileURL = folder.appendingPathComponent(Self.fileName)
    }

    private var mixed: Bool { options.languages.count > 1 }

    /// useMic が false のとき（Macの音を録るとき）は、マイクは使わず fanout に届く音だけを文字にする
    func begin(useMic: Bool) async {
        let ok = await Self.requestSpeechAuthorization()
        guard !finished else { return }
        guard ok else {
            model.status = "音声認識が許可されていません（システム設定 → プライバシーとセキュリティ → 音声認識）。録音後に文字起こしします"
            return
        }
        let ts = options.languages.map { LiveTranscriberFactory.make(language: $0) }
        for t in ts {
            let lang = t.language
            t.onPartial = { [weak self] text in
                DispatchQueue.main.async { self?.partial(text, lang: lang) }
            }
            t.onFinal = { [weak self] piece in
                DispatchQueue.main.async { self?.handleFinal(piece) }
            }
            t.onStatus = { [weak self] text in
                DispatchQueue.main.async { self?.model.status = text }
            }
        }
        transcribers = ts
        let fanout = self.fanout
        mic.onBuffer = { buffer in fanout.append(buffer) }
        Log.write("録音中の文字起こし: \(LiveTranscriberFactory.engineName)、言語: \(options.languages.joined(separator: "+"))、音: \(useMic ? "マイク" : "Macの音")")
        ts.forEach { $0.start(recordingStart: recordingStart) }
        fanout.set(ts)
        guard useMic else {
            startMixedTimer()
            return
        }

        let mic = self.mic
        let queue = workQueue
        let error: Error? = await withCheckedContinuation { (c: CheckedContinuation<Error?, Never>) in
            queue.async {
                do { try mic.start(); c.resume(returning: nil) } catch { c.resume(returning: error) }
            }
        }
        if let error {
            Log.write("マイクを開始できませんでした: \(error.localizedDescription)")
            model.status = "字幕用のマイクを開けませんでした。録音後に文字起こしします"
            let failed = ts
            transcribers = []
            fanout.set([])
            workQueue.async { failed.forEach { $0.stop() } }
            return
        }
        if finished {   // 準備中に録音が終わった
            workQueue.async {
                mic.stop()
                ts.forEach { $0.stop() }
            }
            return
        }
        Log.write("マイク: \(mic.deviceName)")
        startMixedTimer()
    }

    private func startMixedTimer() {
        guard mixed, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushMixed(force: false) }
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// 止めて、最後の確定まで待ってから completion を呼ぶ
    func finish(completion: @escaping @MainActor () -> Void) {
        finished = true
        timer?.invalidate()
        timer = nil
        fanout.set([])
        let ts = transcribers
        transcribers = []
        let mic = self.mic
        workQueue.async {
            mic.stop()
            ts.forEach { $0.stop() }
            Task { @MainActor in
                self.flushMixed(force: true)
                self.partials = [:]
                self.model.setPartial("")
                completion()
            }
        }
    }

    private func partial(_ text: String, lang: String) {
        partials[lang] = text.isEmpty ? nil : (text, Date())
        // 日英混在なら、最後に動いた方を見せる
        model.setPartial(partials.values.max { $0.at < $1.at }?.text ?? "")
    }

    private func handleFinal(_ piece: TranscriptPiece) {
        partials[piece.lang] = nil
        model.setPartial(partials.values.max { $0.at < $1.at }?.text ?? "")
        if mixed {
            pending.append((piece, Date()))
        } else {
            emit(piece)
        }
    }

    /// 日英混在：両方の言語の結果がそろった区間から、確からしい方を選んで出す
    private func flushMixed(force: Bool) {
        guard !pending.isEmpty else { return }
        pending.sort { $0.piece.time < $1.piece.time }
        let now = Date()
        while !pending.isEmpty {
            var end = pending[0].piece.end
            var count = 1
            while count < pending.count, pending[count].piece.time < end + 0.3,
                  end - pending[0].piece.time < 30 {
                end = max(end, pending[count].piece.end)
                count += 1
            }
            let cluster = Array(pending[0..<count])
            if !force {
                let newest = cluster.map(\.arrived).max() ?? now
                let wait = now.timeIntervalSince(newest)
                let bothLanguages = Set(cluster.map(\.piece.lang)).count > 1
                if wait < 2.5 || (!bothLanguages && wait < 6) { break }
            }
            pending.removeFirst(count)
            LanguageMerger.choose(cluster.map(\.piece)).forEach { emit($0) }
        }
    }

    private func emit(_ piece: TranscriptPiece) {
        let id = model.commit(piece)
        model.requestTranslation(id)
        append(piece.line() + "\n")
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.deletingLastPathComponent().path) else { return }   // 破棄された録音
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    // MARK: 保存された live.txt を使えるか

    /// 録音中の文字起こしが最後まで続いていれば、その本文を返す（途中で止まっていたら nil）
    nonisolated static func usableTranscript(in folder: URL, duration: TimeInterval) -> String? {
        let url = folder.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var times: [TimeInterval] = []
        for line in lines {
            guard line.hasPrefix("["), line.count > 10 else { continue }
            let parts = line.dropFirst().prefix(8).split(separator: ":").compactMap { Int($0) }
            if parts.count == 3 { times.append(TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])) }
        }
        times.sort()
        // 10分以上、何も書かれていない区間があれば、途中で止まっていたとみなす
        let maxGap: TimeInterval = 600
        var previous: TimeInterval = 0
        for t in times + [duration] {
            if t - previous > maxGap { return nil }
            previous = max(previous, t)
        }
        return lines.joined(separator: "\n")
    }
}
