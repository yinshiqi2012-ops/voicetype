import AppKit
import Foundation

struct PolishResult: Sendable {
    var text: String
    /// 没能整理时说明原因；成功或用户关闭整理时为 nil。
    var note: String?
}

/// 用本机 Ollama 把转写整理成可直接粘贴的文字。失败时退回原文，不打断输入。
actor SpeechPolisher {
    private var serverProcess: Process?

    func prepare() async {
        guard Config.polishMode != .off else { return }
        guard await ensureServer(), await isModelInstalled() else { return }
        if await isModelLoaded() { return }
        _ = try? await complete(user: "你好", mode: .clean, tokenBudget: 1, allowColdStart: true)
    }

    func polish(_ source: String, mode: PolishMode) async -> PolishResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode != .off, !trimmed.isEmpty else {
            return PolishResult(text: source, note: nil)
        }
        guard await ensureServer() else {
            return PolishResult(text: trimmed, note: "Ollama 没在运行，已插入原文")
        }
        guard await isModelInstalled() else {
            return PolishResult(text: trimmed, note: "整理模型未下载，已插入原文")
        }
        do {
            let generated = try await complete(
                user: trimmed,
                mode: mode,
                tokenBudget: TranscriptCleanup.predictBudget(for: trimmed, mode: mode),
                allowColdStart: true
            )
            guard let text = TranscriptCleanup.sanitize(generated, source: trimmed, mode: mode) else {
                return PolishResult(text: trimmed, note: "整理结果不可用，已插入原文")
            }
            // 事实层面的兜底：数字/时间被改写或丢掉时宁可插原文 ——
            // 说错一个数字、漏掉一个日期，比完全不整理糟得多。
            if let conflict = TranscriptCleanup.entityConflict(source: trimmed, output: text) {
                return PolishResult(text: trimmed, note: "整理会丢信息（\(conflict)），已插入原文")
            }
            return PolishResult(text: text, note: nil)
        } catch let error as URLError where error.code == .timedOut {
            return PolishResult(text: trimmed, note: "整理超时，已插入原文")
        } catch {
            return PolishResult(text: trimmed, note: "整理失败，已插入原文")
        }
    }

    func statusLine() async -> String {
        let model = Config.polishModel
        guard await isReachable() else { return "整理模型：Ollama 未运行" }
        guard await isModelInstalled() else { return "整理模型：未下载 \(model)" }
        if await isModelLoaded() { return "整理模型：\(model)" }
        return "整理模型：\(model)（尚未预热）"
    }

    private func complete(
        user: String,
        mode: PolishMode,
        tokenBudget: Int,
        allowColdStart: Bool
    ) async throws -> String {
        let loaded = await isModelLoaded()
        var request = URLRequest(url: endpoint("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = loaded || !allowColdStart
            ? Config.polishWarmTimeout
            : Config.polishColdTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequest(
            model: Config.polishModel,
            messages: [
                ChatMessage(role: "system", content: TranscriptCleanup.instructions(for: mode)),
                ChatMessage(role: "user", content: user),
            ],
            stream: false,
            think: false,
            // -1 = 永不卸载。口述是随时的，30m 那种 TTL 会让闲置半小时后的
            // 第一句话重新吃 1.5 秒冷启动；常驻反而更省事。
            keepAlive: -1,
            options: ChatOptions(temperature: 0, numPredict: tokenBudget, numCtx: 4096)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw OllamaFailure.status(status) }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let content = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw OllamaFailure.empty }
        return content
    }

    /// 确保本机服务可用。优先拉起已安装的 Ollama.app：登录项、版本、模型目录都由它统一管理。
    /// 只有 App 缺失时才退回 `ollama serve`（homebrew 版可能与 App 版本不一致，会另起一个 daemon）。
    private func ensureServer() async -> Bool {
        if await isReachable() { return true }

        Self.launchOllamaApp()
        if await waitUntilReachable(attempts: 8) { return true }

        if serverProcess?.isRunning != true, let executable = Self.ollamaExecutable() {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                serverProcess = process
            }
        }
        return await waitUntilReachable(attempts: 20)
    }

    private func waitUntilReachable(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            try? await Task.sleep(for: .milliseconds(250))
            if await isReachable() { return true }
        }
        return false
    }

    private static func launchOllamaApp() {
        let bundle = URL(fileURLWithPath: "/Applications/Ollama.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else { return }
        NSWorkspace.shared.open(bundle)
    }

    private func isReachable() async -> Bool {
        var request = URLRequest(url: endpoint("api/version"))
        request.timeoutInterval = 1
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func isModelInstalled() async -> Bool {
        guard let names = try? await modelNames(path: "api/tags") else { return false }
        return names.contains { Self.namesMatch($0, Config.polishModel) }
    }

    private func isModelLoaded() async -> Bool {
        guard let names = try? await modelNames(path: "api/ps") else { return false }
        return names.contains { Self.namesMatch($0, Config.polishModel) }
    }

    private func modelNames(path: String) async throws -> [String] {
        var request = URLRequest(url: endpoint(path))
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { throw OllamaFailure.status(status) }
        let decoded = try JSONDecoder().decode(ModelList.self, from: data)
        return decoded.models.flatMap { [$0.name, $0.model].compactMap { $0 } }
    }

    private func endpoint(_ path: String) -> URL {
        Config.ollamaBaseURL.appending(path: path)
    }

    private static func namesMatch(_ installed: String, _ wanted: String) -> Bool {
        installed == wanted || installed.hasPrefix(wanted + ":")
    }

    private static func ollamaExecutable() -> URL? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private enum OllamaFailure: Error {
    case status(Int)
    case empty
}

private struct ChatRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool
    var think: Bool
    var keepAlive: Int
    var options: ChatOptions

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, options
        case keepAlive = "keep_alive"
    }
}

private struct ChatMessage: Encodable {
    var role: String
    var content: String
}

private struct ChatOptions: Encodable {
    var temperature: Double
    var numPredict: Int
    var numCtx: Int

    enum CodingKeys: String, CodingKey {
        case temperature
        case numPredict = "num_predict"
        case numCtx = "num_ctx"
    }
}

private struct ChatResponse: Decodable {
    struct Message: Decodable {
        var content: String
    }

    var message: Message
}

private struct ModelList: Decodable {
    struct Entry: Decodable {
        var name: String
        var model: String?
    }

    var models: [Entry]
}
