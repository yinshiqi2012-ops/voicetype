import AVFoundation
import Foundation

/// 麦克风录制：`AVAudioEngine` 采集 → 重采样为 16 kHz 单声道 → 16-bit WAV 落盘。
///
/// 落盘的 WAV 既是转写输入，也是后续「历史记录」要引用的音频文件。
final class Recorder {
    enum Failure: Error {
        case noInputDevice
        case unsupportedFormat
        case emptyRecording
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var captured: [AVAudioPCMBuffer] = []
    private var inputFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var destination: URL?

    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInputDevice }
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw Failure.unsupportedFormat
        }

        try FileManager.default.createDirectory(
            at: Config.recordingsDirectory,
            withIntermediateDirectories: true
        )
        let url = Config.recordingsDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        lock.lock()
        captured.removeAll()
        lock.unlock()
        inputFormat = format
        self.file = file
        destination = url

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let copy = Self.copyOf(buffer) else { return }
            self.lock.lock()
            self.captured.append(copy)
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            reset()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        isRecording = true
    }

    /// 结束录制并写出 WAV，返回文件位置与实际时长（秒）。
    func stop() throws -> (url: URL, duration: TimeInterval) {
        guard isRecording else { throw Failure.emptyRecording }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let buffers = captured
        captured.removeAll()
        lock.unlock()

        guard let file, let format = inputFormat, let url = destination, !buffers.isEmpty else {
            if let destination { try? FileManager.default.removeItem(at: destination) }
            reset()
            throw Failure.emptyRecording
        }
        defer { reset() }

        guard let converter = AVAudioConverter(from: format, to: file.processingFormat) else {
            throw Failure.unsupportedFormat
        }

        let ratio = file.processingFormat.sampleRate / format.sampleRate
        var writtenFrames: AVAudioFramePosition = 0

        for buffer in buffers {
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)
            else { continue }

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            switch status {
            case .haveData, .inputRanDry, .endOfStream:
                if output.frameLength > 0 {
                    try file.write(from: output)
                    writtenFrames += AVAudioFramePosition(output.frameLength)
                }
            case .error:
                throw conversionError ?? Failure.unsupportedFormat
            @unknown default:
                break
            }
        }

        let duration = Double(writtenFrames) / file.processingFormat.sampleRate
        return (url, duration)
    }

    private func reset() {
        file = nil
        inputFormat = nil
        destination = nil
    }

    private static func copyOf(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        guard let destination = copy.floatChannelData else { return nil }

        let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(buffer.format.channelCount) {
            memcpy(destination[channel], source[channel], byteCount)
        }
        return copy
    }
}
