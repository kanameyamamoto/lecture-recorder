// オンライン授業用：Macの中の音（Zoomなどの音）を直接録る（MixRec と同じ仕組み）
//
// Core Audio Tap（macOS 14.2 以降）でシステム全体の音を受け取り、5分ごとの .m4a に書き出す。
// 音はスピーカーやイヤホンからいつもどおり聞こえる。受け取った音は文字起こしにも渡す。

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private let queue = DispatchQueue(label: "lecturerecorder.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var file: AVAudioFile?
    /// 音が届くたびに呼ばれる（文字起こし用）。start の前に設定する
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// 録り始める。最初のファイルの書き出し先を渡す
    func start(writingTo url: URL) throws {
        guard #available(macOS 14.2, *) else {
            throw CaptureError.message("Macの音を録るには macOS 14.2 以降が必要です")
        }

        // 1. システム全体の音をステレオで受け取る Tap を作る（音は消さない）
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &tap)
        guard err == noErr else {
            throw CaptureError.coreAudio("Macの音の取得を開始できませんでした", err)
        }
        tapID = tap

        // 2. 今の出力先（スピーカー/AirPods）を土台に、Tap を入力に持つ非公開の装置を作る
        var outAddr = CoreAudioHelper.address(kAudioHardwarePropertyDefaultOutputDevice)
        var outputID = AudioDeviceID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        err = AudioObjectGetPropertyData(CoreAudioHelper.systemObject, &outAddr, 0, nil, &outSize, &outputID)
        guard err == noErr, outputID != AudioDeviceID(kAudioObjectUnknown),
              let outputUID = CoreAudioHelper.stringProperty(outputID, kAudioDevicePropertyDeviceUID) else {
            cleanup()
            throw CaptureError.message("音の出力先（スピーカーやイヤホン）が見つかりません")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LectureRecorder Tap",
            kAudioAggregateDeviceUIDKey: "LectureRecorder-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else {
            cleanup()
            throw CaptureError.coreAudio("録音用の装置を作れませんでした", err)
        }
        aggregateID = agg

        // 3. Tap から届く音の形式を調べる
        var addr = CoreAudioHelper.address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        err = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard err == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            cleanup()
            throw CaptureError.coreAudio("Macの音の形式を読み取れませんでした", err)
        }
        self.format = format
        let first = try makeFile(url, format: format)
        setFile(first)

        // 4. 音が届くたびにファイルへ書き込み、文字起こしにも渡す
        let handler = onBuffer
        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            let f = self.currentFile()
            try? f?.write(from: buffer)
            handler?(buffer)
        }
        guard err == noErr, let procID else {
            cleanup()
            throw CaptureError.coreAudio("Macの音の受け取りを準備できませんでした", err)
        }
        ioProcID = procID
        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else {
            cleanup()
            throw CaptureError.coreAudio("Macの音の録音を開始できませんでした", err)
        }
    }

    /// 次のファイルに切り替える（5分ごと。前のファイルはここで閉じられる）
    func rotate(to url: URL) {
        guard let format else { return }
        do {
            let next = try makeFile(url, format: format)
            setFile(next)
        } catch {
            Log.write("Macの音のファイル切り替えに失敗（今のファイルで続けます）: \(error.localizedDescription)")
        }
    }

    func stop() {
        cleanup()
    }

    // （NSLock の便利な書き方は macOS 14 以降なので、lock/unlock で書く）
    private func setFile(_ f: AVAudioFile?) {
        lock.lock(); file = f; lock.unlock()
    }

    private func currentFile() -> AVAudioFile? {
        lock.lock(); defer { lock.unlock() }
        return file
    }

    /// 容量を抑えるため AAC（.m4a）で書き出す
    private func makeFile(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 128_000,
        ]
        return try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    private func cleanup() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        queue.sync {}   // 書き込み途中の分を待ってから閉じる
        setFile(nil)
    }
}
