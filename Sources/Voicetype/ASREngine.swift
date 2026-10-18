import Foundation

/// 可选的语音识别引擎。
///
/// 前两个走 transcribe.cpp（ggml）加载 Qwen3-ASR 的 GGUF 权重，
/// 最后一个保留原来的 WhisperKit 实现作为对照与回退。
///
/// 中文准确率取自 transcribe.cpp 官方 catalog 的 `fleurs-zh` CER（945 条，Q8_0，越低越好）：
/// `qwen3-asr-0.6b` 7.57、`qwen3-asr-1.7b` 7.14、`whisper-small` 23.06。
/// 实测（本机 6 条真实口述）：0.6B 与 1.7B 互有胜负，1.7B 更慢更占内存。
enum ASREngine: String, CaseIterable, Sendable {
    case qwen06 = "qwen3-asr-0.6b"
    case qwen17 = "qwen3-asr-1.7b"
    case whisperSmall = "whisper-small"

    var menuTitle: String {
        switch self {
        case .qwen06: return "Qwen3-ASR 0.6B（中文 7.6%，推荐）"
        case .qwen17: return "Qwen3-ASR 1.7B（中文 7.1%，更吃内存）"
        case .whisperSmall: return "Whisper small（旧，中文 23%）"
        }
    }

    /// 菜单标题用的短名。
    var shortTitle: String {
        switch self {
        case .qwen06: return "Qwen3-ASR 0.6B"
        case .qwen17: return "Qwen3-ASR 1.7B"
        case .whisperSmall: return "Whisper small"
        }
    }

    /// GGUF 权重文件名；`nil` 表示不用 transcribe.cpp（走 WhisperKit）。
    var ggufFileName: String? {
        switch self {
        case .qwen06: return "qwen3-asr-0.6b-Q8_0.gguf"
        case .qwen17: return "qwen3-asr-1.7b-Q8_0.gguf"
        case .whisperSmall: return nil
        }
    }

    /// 缺权重时从 hf-mirror 下载的相对路径（官方 huggingface.co 在部分网络下不可达）。
    var downloadPath: String? {
        switch self {
        case .qwen06:
            return "handy-computer/Qwen3-ASR-0.6B-gguf/resolve/main/Qwen3-ASR-0.6B-Q8_0.gguf"
        case .qwen17:
            return "handy-computer/Qwen3-ASR-1.7B-gguf/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf"
        case .whisperSmall:
            return nil
        }
    }

    var downloadSizeLabel: String {
        switch self {
        case .qwen06: return "811MB"
        case .qwen17: return "2.0GB"
        case .whisperSmall: return "-"
        }
    }
}
