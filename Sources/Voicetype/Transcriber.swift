import AVFoundation
import Foundation
@preconcurrency import WhisperKit
import TranscribeCpp

/// 语音转写：把录音 WAV 变成文字，全程本机，音频不出网。
///
/// 两种引擎并存：
/// - `TranscribeCpp`（ggml）+ Qwen3-ASR 的 GGUF 权重，中文准确率显著更高；
/// - `WhisperKit` + Core ML，保留作为对照与回退。
///
/// 用 actor 隔离：`Model`/`Session`/`WhisperKit` 都不是 `Sendable`，
/// 而调用方是主线程上的串行流程（一次录音结束才转写一次），actor 让串行语义明确。
actor Transcriber {
    enum Failure: Error, CustomStringConvertible {
        case notLoaded
        case modelMissing(String)
        case tokenizerDownloadFailed(String)
        case audioUnreadable(String)

        var description: String {
            switch self {
            case .notLoaded:
                return "识别模型尚未加载"
            case .modelMissing(let name):
                return "缺少识别模型 \(name)"
            case .tokenizerDownloadFailed(let file):
                return "tokenizer 下载失败：\(file)"
            case .audioUnreadable(let reason):
                return "音频读取失败：\(reason)"
            }
        }
    }

    /// WhisperKit 本地加载 tokenizer 时必需的两个文件（缺 `tokenizer_config.json`
    /// 会导致 tokenizer_class 无法解析）。
    private static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    private var whisper: WhisperKit?
    private var whisperLoadTask: Task<Void, Error>?

    private var qwenModel: Model?
    private var qwenSession: Session?

    private var loadedEngine: ASREngine?

    /// 当前选中的引擎是否已就绪。
    var isLoaded: Bool { loadedEngine == Config.asrEngine }

    /// 切到另一个引擎时调用：先释放旧引擎再加载新的。
    func reload() async throws {
        unload()
        try await load()
    }

    /// 按当前选择加载引擎；已加载则直接返回。
    func load() async throws {
        let engine = Config.asrEngine
        if loadedEngine == engine { return }
        unload()

        switch engine {
        case .whisperSmall:
            try await loadWhisper()
        case .qwen06, .qwen17:
            try await loadQwen(engine)
        }
        loadedEngine = engine
    }

    /// 释放原生资源。ggml-metal 的 residency set 要求退出前释放 GPU 资源。
    func unload() {
        qwenSession = nil
        qwenModel = nil
        whisper = nil
        whisperLoadTask = nil
        loadedEngine = nil
    }

    /// 转写单个 WAV 文件，返回纯文本。
    func transcribe(audioURL: URL, language: String?) async throws -> String {
        try await load()

        let text: String
        if loadedEngine == .whisperSmall {
            text = try await transcribeWithWhisper(audioURL: audioURL, language: language)
        } else {
            text = try await transcribeWithQwen(audioURL: audioURL, language: language)
        }
        return Self.simplified(text, language: language)
    }

    // MARK: - Qwen3-ASR（transcribe.cpp）

    private func loadQwen(_ engine: ASREngine) async throws {
        let url = try await ensureWeights(for: engine)
        Transcribe.disableLogging()
        let model = try Model(path: url.path)
        qwenModel = model
        qwenSession = try model.session()
    }

    private func transcribeWithQwen(audioURL: URL, language: String?) async throws -> String {
        guard let qwenSession else { throw Failure.notLoaded }
        let pcm = try Self.pcm16k(from: audioURL)

        var options = RunOptions()
        // 固定中文：自动检测在夹杂英文时偶发判成 en，反而更差。
        options.language = language ?? "zh"
        let transcript = try await qwenSession.run(pcm, options: options)
        return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 取 GGUF 权重；缺失时从 hf-mirror 下载（官方端点在国内常不可达）。
    private func ensureWeights(for engine: ASREngine) async throws -> URL {
        guard let fileName = engine.ggufFileName, let remotePath = engine.downloadPath else {
            throw Failure.modelMissing(engine.rawValue)
        }
        let directory = Config.asrModelsDirectory
        let destination = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let endpoint = Config.modelEndpoint ?? "https://huggingface.co"
        guard let url = URL(string: "\(endpoint)/\(remotePath)") else {
            throw Failure.modelMissing(engine.rawValue)
        }

        var latest: Error = Failure.modelMissing(engine.rawValue)
        for _ in 0..<2 {
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status) else {
                    throw Failure.modelMissing("\(engine.rawValue) HTTP \(status)")
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return destination
            } catch {
                latest = error
            }
        }
        throw latest
    }

    // MARK: - WhisperKit（保留）

    private func loadWhisper() async throws {
        if whisper != nil { return }
        if let whisperLoadTask { return try await whisperLoadTask.value }

        let task = Task { () -> Void in
            try FileManager.default.createDirectory(
                at: Config.modelsDirectory,
                withIntermediateDirectories: true
            )
            try await self.ensureTokenizer()
            // 本地已有 Core ML 模型时直接指定目录并关掉下载：
            // 否则 WhisperKit 仍会去服务器校验元数据，端点不可达就整个加载失败。
            let localFolder = Config.localModelFolder
            let config = WhisperKitConfig(
                model: Config.modelName,
                downloadBase: Config.modelsDirectory,
                modelEndpoint: Config.modelEndpoint,
                modelFolder: localFolder?.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: localFolder == nil
            )
            let kit = try await WhisperKit(config)
            await self.adopt(kit)
        }
        whisperLoadTask = task

        do {
            try await task.value
        } catch {
            whisperLoadTask = nil
            throw error
        }
    }

    private func adopt(_ kit: WhisperKit) {
        whisper = kit
    }

    private func transcribeWithWhisper(audioURL: URL, language: String?) async throws -> String {
        guard let whisper else { throw Failure.notLoaded }
        let options = DecodingOptions(language: language, detectLanguage: language == nil)
        let results = try await whisper.transcribe(audioPath: audioURL.path, decodeOptions: options)
        return results
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 预置 tokenizer 到 WhisperKit 期望的 hub 路径。
    ///
    /// WhisperKit 的 tokenizer 下载路径不接受 `modelEndpoint`，只读 `HF_ENDPOINT`
    /// 环境变量，官方端点在部分网络下不可达。因此这里直接按同一套
    /// `models/<repoId>` 布局把文件落盘，让 WhisperKit 命中本地加载分支。
    private func ensureTokenizer() async throws {
        let directory = Config.tokenizerDirectory
        let targets = Self.tokenizerFiles.map { directory.appendingPathComponent($0) }
        if targets.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let endpoint = Config.modelEndpoint ?? "https://huggingface.co"

        for file in Self.tokenizerFiles {
            try await downloadTokenizer(file, from: endpoint, into: directory)
        }
    }

    private func downloadTokenizer(_ file: String, from endpoint: String, into directory: URL) async throws {
        guard let url = URL(string: "\(endpoint)/\(Config.tokenizerRepo)/resolve/main/\(file)") else {
            throw Failure.tokenizerDownloadFailed(file)
        }

        var latest: Error = Failure.tokenizerDownloadFailed(file)
        for _ in 0..<2 {
            do {
                let (temporaryURL, response) = try await URLSession.shared.download(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard (200..<300).contains(status) else {
                    throw Failure.tokenizerDownloadFailed("\(file) HTTP \(status)")
                }
                let destination = directory.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                return
            } catch {
                latest = error
            }
        }
        throw latest
    }

    // MARK: - 音频

    /// 把 WAV 读成 16kHz 单声道 Float32 PCM（transcribe.cpp 的输入契约）。
    ///
    /// 本应用录制的就是 16kHz/单声道/Int16，走零拷贝快路径；
    /// 其他格式（含用户手动放入的文件）用 AVAudioConverter 转一次。
    nonisolated static func pcm16k(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.audioUnreadable(error.localizedDescription)
        }

        let inputFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
        else { throw Failure.audioUnreadable("空音频或无法分配缓冲区") }

        do {
            try file.read(into: input)
        } catch {
            throw Failure.audioUnreadable(error.localizedDescription)
        }

        if inputFormat.sampleRate == 16_000, inputFormat.channelCount == 1,
           let data = input.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(input.frameLength)))
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw Failure.audioUnreadable("不支持的音频格式")
        }

        let capacity = AVAudioFrameCount(
            Double(input.frameLength) * 16_000 / inputFormat.sampleRate
        ) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure.audioUnreadable("无法分配转换缓冲区")
        }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw Failure.audioUnreadable(conversionError.localizedDescription) }
        guard let data = output.floatChannelData else {
            throw Failure.audioUnreadable("重采样失败")
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// 繁体 → 简体；仅在中文识别时生效，基于 ICU 转换，不依赖模型。
    private static func simplified(_ text: String, language: String?) -> String {
        let target = language ?? "zh"
        guard target.hasPrefix("zh"), !text.isEmpty else { return text }
        return text.applyingTransform(
            StringTransform(rawValue: "Traditional-Simplified"),
            reverse: false
        ) ?? text
    }
}
