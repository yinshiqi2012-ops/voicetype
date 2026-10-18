import Foundation

/// 全局常量与可覆盖配置。
///
/// 可用 `defaults write com.truman.voicetype model openai_whisper-large-v3-turbo`
/// 覆盖模型；识别语言默认固定为 `zh`，`defaults write com.truman.voicetype language ""`
/// 可恢复自动检测。
enum Config {
    /// 录音热键：Option + Command 同时按下触发一次，再按一次结束。
    /// 具体按键识别在 `HotKeyMonitor`（按修饰键 flags 判断，左右 Option/Command 都可以）。
    /// 用组合键而不是单键，是为了避开单独按 Option 时与系统快捷键、输入法冲突。

    /// 默认模型。首次运行会从 HuggingFace 下载到 `Models` 目录。
    static let defaultModel = "openai_whisper-small"

    /// 默认 HuggingFace 端点。官方 `huggingface.co` 在部分网络下不可达，故默认走镜像。
    /// 可用 `defaults write com.truman.voicetype modelEndpoint ""` 切回官方端点。
    static let defaultModelEndpoint = "https://hf-mirror.com"

    /// 最长录制时长（秒），超时自动结束并转写。
    static let maximumRecordingSeconds: TimeInterval = 120

    /// 低于该时长的录音视为误触，直接丢弃。
    static let minimumRecordingSeconds: TimeInterval = 0.35

    /// 本地整理模型。国行 Mac 不能用 Apple 端侧模型，默认走本机 Ollama 的 Qwen3.5 9B。
    /// 覆盖：`defaults write com.truman.voicetype polishModel qwen3.5:9b`
    static let defaultPolishModel = "qwen3.5:9b"

    /// 整理请求在模型已载入内存时的等待上限。冷启动另有更长的加载上限。
    static let polishWarmTimeout: TimeInterval = 12
    static let polishColdTimeout: TimeInterval = 45

    static var polishModel: String {
        let value = UserDefaults.standard.string(forKey: "polishModel") ?? defaultPolishModel
        return value.isEmpty ? defaultPolishModel : value
    }

    /// `clean` 去废话并理顺，`summary` 压成要点，`off` 保持转写原文。
    /// 覆盖：`defaults write com.truman.voicetype polishMode summary`
    static var polishMode: PolishMode {
        get {
            let raw = UserDefaults.standard.string(forKey: "polishMode") ?? PolishMode.clean.rawValue
            return PolishMode(rawValue: raw) ?? .clean
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "polishMode")
        }
    }

    static var ollamaBaseURL: URL {
        let raw = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        return URL(string: raw) ?? URL(string: "http://127.0.0.1:11434")!
    }

    static var modelName: String {
        UserDefaults.standard.string(forKey: "model") ?? defaultModel
    }

    // MARK: - 识别引擎

    /// 当前使用的识别引擎。默认 Qwen3-ASR 0.6B：官方 `fleurs-zh` CER 7.57%，
    /// 是原来的 Whisper-small（23.06%）的三倍精度，速度还快 2–3 倍。
    /// 覆盖：`defaults write com.truman.voicetype asrEngine qwen3-asr-1.7b`
    static var asrEngine: ASREngine {
        get {
            let raw = UserDefaults.standard.string(forKey: "asrEngine") ?? ""
            return ASREngine(rawValue: raw) ?? .qwen06
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "asrEngine") }
    }

    /// GGUF 权重目录（transcribe.cpp 引擎用）。
    static var asrModelsDirectory: URL {
        supportDirectory.appendingPathComponent("Models/ASR", isDirectory: true)
    }

    /// 模型下载端点；空字符串表示使用 WhisperKit 默认（官方 huggingface.co）。
    static var modelEndpoint: String? {
        let value = UserDefaults.standard.string(forKey: "modelEndpoint") ?? defaultModelEndpoint
        return value.isEmpty ? nil : value
    }

    /// 默认识别语言。固定为中文，避免 Whisper 自动检测中文时偏向繁体输出。
    static let defaultLanguage = "zh"

    /// 识别语言；默认固定为简体中文。写入空字符串可恢复自动检测：
    /// `defaults write com.truman.voicetype language ""`
    static var language: String? {
        let value = UserDefaults.standard.string(forKey: "language") ?? defaultLanguage
        return value.isEmpty ? nil : value
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("voicetype", isDirectory: true)
    }

    static var recordingsDirectory: URL {
        supportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    /// tokenizer 仓库 id，由模型名推导（`openai_whisper-small` → `openai/whisper-small`）。
    static var tokenizerRepo: String {
        modelName.replacingOccurrences(of: "_", with: "/")
    }

    /// tokenizer 落盘目录，必须与 WhisperKit 的 hub 布局一致：
    /// `tokenizerFolder` 就是 `modelsDirectory`，`localRepoLocation` 再拼 `models/<repoId>`。
    static var tokenizerDirectory: URL {
        modelsDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(tokenizerRepo, isDirectory: true)
    }

    /// 本地已下载的 Core ML 模型目录（WhisperKit hub 布局 `models/<repo>/<modelName>`）。
    ///
    /// 交给 `WhisperKitConfig.modelFolder` 后，WhisperKit 会**完全跳过联网下载与元数据校验**。
    /// 这一步是必需的：官方端点不可达时，WhisperKit 即使本地文件齐全也会抛
    /// `invalidMetadataError("File metadata must have been retrieved from server")`，
    /// 表现为「模型明明在本地却加载失败」。
    ///
    /// 不硬编码 repo 名，扫一层匹配即可（升级模型时目录名不变）。
    static var localModelFolder: URL? {
        let root = modelsDirectory.appendingPathComponent("models", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return nil }
        // hub 布局可能是 `models/<repo>/<modelName>` 或 `models/<org>/<repo>/<modelName>`，
        // 直接按目录名匹配 + 关键模型文件存在来判定，不假设层级。
        for case let url as URL in walker where url.lastPathComponent == modelName {
            let marker = url.appendingPathComponent("MelSpectrogram.mlmodelc")
            if FileManager.default.fileExists(atPath: marker.path) { return url }
        }
        return nil
    }
}

/// 转写之后、插入光标之前，对文字做哪一种处理。
enum PolishMode: String, CaseIterable, Sendable {
    case off
    case clean
    case summary

    var menuTitle: String {
        switch self {
        case .off: "插入原文"
        case .clean: "整理后插入"
        case .summary: "总结成要点"
        }
    }
}
