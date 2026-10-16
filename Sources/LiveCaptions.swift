// 録音中の字幕ウィンドウと翻訳
//
// 文字起こしそのものは LiveTranscription.swift（録音中はいつも動いている）。
// ここでは、その結果を字幕ウィンドウに出し、必要なら Translation フレームワーク
// （macOS 15 以降、Mac内で翻訳）で訳を付ける。

import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: - 設定（授業ごとに覚える）

struct LiveCaptionOptions: Codable, Equatable {
    static let japanese = "ja-JP"
    static let english = "en-US"
    static let mixed = "mixed"          // 日本語と英語が混ざる授業

    var enabled = false                 // 字幕ウィンドウを出すか
    var language = LiveCaptionOptions.japanese   // 授業で話される言語
    var translate = false
    var captureSystem = false           // Macの音も録る（オンライン授業）

    init(enabled: Bool = false, language: String = LiveCaptionOptions.japanese,
         translate: Bool = false, captureSystem: Bool = false) {
        self.enabled = enabled
        self.language = language
        self.translate = translate
        self.captureSystem = captureSystem
    }

    // 項目が増えても、前に保存した設定を読めるようにする
    private enum CodingKeys: String, CodingKey { case enabled, language, translate, captureSystem }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? Self.japanese
        translate = try c.decodeIfPresent(Bool.self, forKey: .translate) ?? false
        captureSystem = try c.decodeIfPresent(Bool.self, forKey: .captureSystem) ?? false
    }

    var isEnglish: Bool { language == Self.english }
    var isMixed: Bool { language == Self.mixed }

    /// 実際に認識する言語（日英混在は macOS 26 以降で2つ同時に）
    var languages: [String] {
        if isMixed { return Self.mixedAvailable ? [Self.japanese, Self.english] : [Self.japanese] }
        return [isEnglish ? Self.english : Self.japanese]
    }

    /// 訳す元の言語（英語の授業は日本語訳、日本語・日本語と英語の授業は日本語の部分を英訳）
    var translationSource: String { isEnglish ? Self.english : Self.japanese }

    var translationLabel: String { isEnglish ? "日本語訳" : "英訳" }

    var languageLabel: String {
        if isMixed { return "日英混在" }
        return isEnglish ? "英語" : "日本語"
    }

    /// このMacで翻訳が使えるか（macOS 15 以降）
    static var translationAvailable: Bool {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { return true }
        #endif
        return false
    }

    /// 日英混在（2つの言語で同時に認識）が使えるか（macOS 26 以降）
    static var mixedAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// 授業名から話す言語を推測する（初めて選んだ授業だけ）
    static func guessLanguage(for name: String) -> String {
        let lower = name.lowercased()
        let english = ["英語", "english", "pbe", "toeic", "toefl", "ielts"]
        return english.contains { lower.contains($0) } ? Self.english : Self.japanese
    }

    private static func key(_ name: String) -> String { "liveCaption." + name }

    static func load(for name: String) -> LiveCaptionOptions {
        if let data = UserDefaults.standard.data(forKey: key(name)),
           let o = try? JSONDecoder().decode(LiveCaptionOptions.self, from: data) {
            return o
        }
        var o = LiveCaptionOptions()
        o.language = guessLanguage(for: name)
        return o
    }

    func save(for name: String) {
        guard !name.isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(name))
    }
}

// MARK: - 字幕の中身

struct CaptionLine: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var lang: String
    var translation: String?
}

@MainActor
final class LiveCaptionModel: ObservableObject {
    let options: LiveCaptionOptions
    let title: String

    @Published private(set) var lines: [CaptionLine] = []
    @Published private(set) var partial = ""
    @Published var status: String?            // 文字起こしのお知らせ（エラーなど）
    @Published var translationStatus: String? // 翻訳のお知らせ
    @Published private(set) var revision = 0  // 表示が変わるたびに増やす（自動スクロール用）
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "liveCaption.fontSize") }
    }

    private var jobs: [UUID] = []
    private static let maxLines = 300

    init(options: LiveCaptionOptions, title: String) {
        self.options = options
        self.title = title
        let saved = UserDefaults.standard.double(forKey: "liveCaption.fontSize")
        fontSize = saved > 0 ? saved : 16
    }

    var translates: Bool { options.translate && LiveCaptionOptions.translationAvailable }

    func setPartial(_ text: String) {
        guard partial != text else { return }
        partial = text
        revision += 1
    }

    /// 確定した区間を1行として足す
    @discardableResult
    func commit(_ piece: TranscriptPiece) -> UUID {
        let line = CaptionLine(text: piece.text, lang: piece.lang)
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        revision += 1
        return line.id
    }

    /// 訳す元の言語の行だけ、翻訳待ちに入れる
    func requestTranslation(_ id: UUID) {
        guard translates, !jobs.contains(id),
              let line = lines.first(where: { $0.id == id }),
              line.lang == options.translationSource else { return }
        jobs.append(id)
    }

    func nextTranslationJob() -> (id: UUID, text: String)? {
        while !jobs.isEmpty {
            let id = jobs.removeFirst()
            if let line = lines.first(where: { $0.id == id }), !line.text.isEmpty { return (id, line.text) }
        }
        return nil
    }

    /// 字幕をまとめた文字（訳があれば原文の次の行に）
    var copyText: String {
        lines.map { line in
            line.translation.map { line.text + "\n" + $0 } ?? line.text
        }.joined(separator: "\n")
    }

    func setTranslation(_ text: String, for id: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].translation = text
        translationStatus = nil
        revision += 1
    }
}

// MARK: - 字幕ウィンドウ

struct LiveCaptionView: View {
    @ObservedObject var model: LiveCaptionModel
    var onClose: @MainActor () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "captions.bubble")
                Text(header).lineLimit(1).padding(.leading, 2)
                Spacer(minLength: 12)
                // 文字の大きさ（日本語の環境だと記号が「あ」になるので、英語の記号にそろえる）
                headerButton("textformat.size.smaller", help: "文字を小さく") {
                    model.fontSize = max(11, model.fontSize - 2)
                }
                headerButton("textformat.size.larger", help: "文字を大きく") {
                    model.fontSize = min(40, model.fontSize + 2)
                }
                Divider().frame(height: 14).padding(.horizontal, 4)
                headerButton(copied ? "checkmark" : "doc.on.doc", help: "字幕をすべてコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.copyText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(model.lines.isEmpty)
                    .padding(.trailing, 10)   // コピーと×の間を少し空ける
                headerButton("xmark", help: "字幕を隠す（メニューの「字幕を表示」でまた出せます）") {
                    onClose()
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.65))
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if let s = model.status ?? model.translationStatus {
                Text(s)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.lines.isEmpty && model.partial.isEmpty {
                            Text("聞き取り中…").foregroundStyle(.white.opacity(0.45))
                        }
                        ForEach(model.lines) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.text).foregroundStyle(.white)
                                if let t = line.translation {
                                    Text(t).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.35))
                                }
                            }
                        }
                        if !model.partial.isEmpty {
                            Text(model.partial).foregroundStyle(.white.opacity(0.6))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(.system(size: model.fontSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .onChange(of: model.revision) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 120)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.8)))
        .modifier(TranslationRunner(model: model))
    }

    /// 上の列のボタン（大きさと間隔をそろえる）
    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .environment(\.locale, Locale(identifier: "en_US"))
        .help(help)
    }

    private var header: String {
        var s = "字幕（\(model.options.languageLabel)）"
        if model.translates { s += "＋\(model.options.translationLabel)" }
        if !model.title.isEmpty { s += "　\(model.title)" }
        return s
    }
}

/// macOS 15 以降なら、字幕の行を順に翻訳する
private struct TranslationRunner: ViewModifier {
    let model: LiveCaptionModel

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(Translation)
        if model.translates {
            if #available(macOS 15.0, *) {
                content.modifier(TranslationTaskModifier(model: model))
            } else {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct TranslationTaskModifier: ViewModifier {
    let model: LiveCaptionModel
    let configuration: TranslationSession.Configuration
    let source: Locale.Language
    let target: Locale.Language

    init(model: LiveCaptionModel) {
        self.model = model
        let fromEnglish = model.options.translationSource == LiveCaptionOptions.english
        source = Locale.Language(identifier: fromEnglish ? "en" : "ja")
        target = Locale.Language(identifier: fromEnglish ? "ja" : "en")
        configuration = TranslationSession.Configuration(source: source, target: target)
    }

    func body(content: Content) -> some View {
        content.translationTask(configuration) { session in
            let model = self.model
            let status = await LanguageAvailability().status(from: source, to: target)
            switch status {
            case .installed:
                break
            case .supported:
                await MainActor.run {
                    model.translationStatus = "翻訳用の言語データをダウンロードします（確認の画面が出たら「ダウンロード」を押してください）"
                }
                do {
                    try await session.prepareTranslation()
                } catch {
                    await MainActor.run {
                        model.translationStatus = "翻訳の言語データがありません。システム設定 → 一般 → 言語と地域 → 翻訳言語 から「日本語」と「英語」をダウンロードしてください"
                    }
                }
            case .unsupported:
                await MainActor.run { model.translationStatus = "この言語の組み合わせは翻訳できません" }
                return
            @unknown default:
                break
            }
            while !Task.isCancelled {
                if let job = await model.nextTranslationJob() {
                    do {
                        let response = try await session.translate(job.text)
                        await model.setTranslation(response.targetText, for: job.id)
                    } catch {
                        await MainActor.run {
                            model.translationStatus = "翻訳できませんでした：\(error.localizedDescription)"
                        }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }
}
#endif

// MARK: - 字幕ウィンドウを作る

@MainActor
enum LiveCaptionPanel {
    static func make(model: LiveCaptionModel, onClose: @escaping @MainActor () -> Void) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 220),
                            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 120)
        let host = NSHostingView(rootView: LiveCaptionView(model: model, onClose: onClose))
        panel.contentView = host

        // 前回の位置・大きさ。なければ画面の下の中央
        if !panel.setFrameUsingName("LiveCaptions"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrame(NSRect(x: v.midX - 360, y: v.minY + 40, width: 720, height: 220), display: false)
        }
        panel.setFrameAutosaveName("LiveCaptions")
        return panel
    }
}
