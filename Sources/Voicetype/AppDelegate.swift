import AppKit
import AVFoundation
import Foundation
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// 链路日志：`log show --predicate 'subsystem == "com.truman.voicetype"' --last 10m`
    private let pipeline = Logger(subsystem: "com.truman.voicetype", category: "pipeline")
    private let transcriber = Transcriber()
    private let recorder = Recorder()
    private let polisher = SpeechPolisher()
    private var monitor: HotKeyMonitor?

    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var hintLine: NSMenuItem?
    private var permissionLine: NSMenuItem?
    private var loginItemMenu: NSMenuItem?
    private var polishModelLine: NSMenuItem?
    private var polishModeItems: [PolishMode: NSMenuItem] = [:]
    private var compareItem: NSMenuItem?
    private var asrEngineMenu: NSMenuItem?
    private var asrEngineItems: [ASREngine: NSMenuItem] = [:]

    private var autoStopTimer: Timer?
    private var isTranscribing = false
    private var isPolishing = false
    private var isModelReady = false
    private var lastError: String?
    private var statusNote: String?
    /// 上一轮的识别原文与最终插入内容，用于菜单里对比整理效果。
    private var lastSource: String?
    private var lastPolished: String?
    private var autoStopArmed = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpHotKey()
        requestMissingPermissions()
        warmUpModel()
        warmUpPolisher()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelAutoStop()
        monitor?.stop()
        // ggml-metal 要求退出前释放 GPU 资源，否则可能在 teardown 时断言。
        // 退出路径是同步的，这里最多等 1 秒把权重放掉。
        let released = DispatchSemaphore(value: 0)
        Task {
            await transcriber.unload()
            released.signal()
        }
        _ = released.wait(timeout: .now() + 1)
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "voicetype")
        item.button?.toolTip = "voicetype：按住右 Option 说话"

        let menu = NSMenu()
        menu.delegate = self

        let hint = NSMenuItem(title: hintTitle(), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        hintLine = hint

        let status = NSMenuItem(title: "状态：启动中…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status

        let permission = NSMenuItem(
            title: "权限：检查中…",
            action: #selector(openPermissionSettings),
            keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)
        permissionLine = permission

        menu.addItem(.separator())

        let asrItem = NSMenuItem(title: "识别模型", action: nil, keyEquivalent: "")
        let asrMenu = NSMenu()
        for engine in ASREngine.allCases {
            let entry = NSMenuItem(
                title: engine.menuTitle,
                action: #selector(selectASREngine(_:)),
                keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = engine.rawValue
            entry.state = Config.asrEngine == engine ? .on : .off
            asrMenu.addItem(entry)
            asrEngineItems[engine] = entry
        }
        asrItem.submenu = asrMenu
        menu.addItem(asrItem)
        asrEngineMenu = asrItem
        refreshASRMenu()

        menu.addItem(.separator())
        for mode in PolishMode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectPolishMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
            polishModeItems[mode] = item
        }
        let polishModel = NSMenuItem(title: "整理模型：检查中…", action: nil, keyEquivalent: "")
        polishModel.isEnabled = false
        menu.addItem(polishModel)
        polishModelLine = polishModel

        let compare = NSMenuItem(
            title: "查看上次结果对比",
            action: #selector(showLastComparison),
            keyEquivalent: ""
        )
        compare.target = self
        compare.isEnabled = false
        menu.addItem(compare)
        compareItem = compare

        refreshPolishMenu()

        let loginItem = NSMenuItem(
            title: "开机自启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.target = self
        menu.addItem(loginItem)
        loginItemMenu = loginItem
        refreshLoginItemLine()

        let recordings = NSMenuItem(title: "打开录音目录", action: #selector(openRecordings), keyEquivalent: "")
        recordings.target = self
        menu.addItem(recordings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 voicetype",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func openRecordings() {
        try? FileManager.default.createDirectory(
            at: Config.recordingsDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(Config.recordingsDirectory)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LoginItem.setEnabled(LoginItem.state != .enabled)
        } catch {
            lastError = "设置开机自启失败：\(error.localizedDescription)"
        }
        refreshLoginItemLine()
        refreshStatusLine()
    }

    private func refreshLoginItemLine() {
        switch LoginItem.state {
        case .enabled:
            loginItemMenu?.state = .on
            loginItemMenu?.title = "开机自启动"
        case .requiresApproval:
            loginItemMenu?.state = .off
            loginItemMenu?.title = "开机自启动（需在系统设置中允许）"
        case .disabled:
            loginItemMenu?.state = .off
            loginItemMenu?.title = "开机自启动"
        }
    }

    @objc private func openPermissionSettings() {
        if !Permissions.hasAccessibility || !Permissions.canPostEvents {
            Permissions.openSettings(for: Permissions.accessibilitySettingsURL)
        } else if !Permissions.hasInputMonitoring {
            Permissions.openSettings(for: Permissions.inputMonitoringSettingsURL)
        } else if !Permissions.hasMicrophone {
            Permissions.openSettings(for: Permissions.microphoneSettingsURL)
        }
    }

    private func refreshStatusLine(recording: Bool = false) {
        let state: String
        let symbol: String
        if let lastError {
            state = lastError
            symbol = "exclamationmark.triangle"
        } else if recording {
            state = "正在录音…（松开右 Option 结束）"
            symbol = "mic.fill"
        } else if isPolishing {
            state = Config.polishMode == .summary ? "正在总结…" : "正在整理…"
            symbol = "sparkles"
        } else if isTranscribing {
            state = "正在识别…"
            symbol = "waveform"
        } else if !isModelReady {
            state = "正在准备语音模型（首次运行需下载）"
            symbol = "arrow.down.circle"
        } else if let statusNote {
            state = statusNote
            symbol = "quote.bubble"
        } else {
            state = "就绪，按住右 Option 说话"
            symbol = "mic"
        }
        statusLine?.title = "状态：" + state
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state) {
            statusItem?.button?.image = image
        }
    }

    private func refreshPermissionLine() {
        let microphone = Permissions.microphoneLabel()
        let accessibility = Permissions.hasAccessibility && Permissions.canPostEvents ? "✓" : "✗"
        let inputMonitoring = Permissions.hasInputMonitoring ? "✓" : "✗"
        permissionLine?.title =
            "权限（点击打开设置）：麦克风 \(microphone)｜辅助功能 \(accessibility)｜输入监控 \(inputMonitoring)"
    }

    // MARK: - 权限

    private func requestMissingPermissions() {
        if Permissions.microphoneStatus == .notDetermined {
            Permissions.requestMicrophone { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissionLine() }
            }
        }
        if !Permissions.hasAccessibility {
            Permissions.promptAccessibility()
        }
        if !Permissions.hasInputMonitoring {
            Permissions.requestInputMonitoring()
        }
        if !Permissions.canPostEvents {
            Permissions.requestPostEvents()
        }
        refreshPermissionLine()
    }

    // MARK: - 模型

    private func warmUpModel() {
        refreshStatusLine()
        Task {
            do {
                let started = Date()
                try await transcriber.load()
                isModelReady = true
                pipeline.notice("asr ready: engine=\(Config.asrEngine.rawValue, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public)s")
                // 只有热键监听已建立时才清错误，否则会把启动时的权限错误抹掉。
                if monitor != nil {
                    lastError = nil
                }
            } catch {
                pipeline.error("model load failed: \(String(describing: error), privacy: .public)")
                lastError = "模型加载失败：\(error)"
            }
            refreshStatusLine()
        }
    }

    private func warmUpPolisher() {
        guard Config.polishMode != .off else { return }
        Task { await polisher.prepare() }
    }

    private func hintTitle() -> String {
        switch Config.polishMode {
        case .off: "按住右 Option 说话，松开即转写并插入"
        case .clean: "按住右 Option 说话，松开后整理并插入"
        case .summary: "按住右 Option 说话，松开后总结并插入"
        }
    }

    private func refreshPolishMenu() {
        hintLine?.title = hintTitle()
        statusItem?.button?.toolTip = "voicetype：" + hintTitle()
        for mode in PolishMode.allCases {
            polishModeItems[mode]?.state = Config.polishMode == mode ? .on : .off
        }
    }

    @objc private func selectPolishMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = PolishMode(rawValue: raw)
        else { return }
        Config.polishMode = mode
        statusNote = nil
        refreshPolishMenu()
        refreshStatusLine()
        if mode != .off {
            Task { await polisher.prepare() }
        }
    }

    @objc private func selectASREngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = ASREngine(rawValue: raw),
              engine != Config.asrEngine
        else { return }

        Config.asrEngine = engine
        refreshASRMenu()
        isModelReady = false
        lastError = nil
        statusNote = nil
        refreshStatusLine()
        pipeline.notice("asr engine -> \(engine.rawValue, privacy: .public)")

        Task {
            do {
                try await transcriber.reload()
                isModelReady = true
                if monitor != nil { lastError = nil }
            } catch {
                pipeline.error("asr load failed: \(String(describing: error), privacy: .public)")
                lastError = "识别模型加载失败：\(error)"
            }
            refreshStatusLine()
        }
    }

    private func refreshASRMenu() {
        for (engine, item) in asrEngineItems {
            item.state = Config.asrEngine == engine ? .on : .off
        }
        asrEngineMenu?.title = "识别模型：\(Config.asrEngine.shortTitle)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshPolishMenu()
        Task {
            let line = await polisher.statusLine()
            polishModelLine?.title = line
        }
    }

    // MARK: - 热键

    private func setUpHotKey() {
        let monitor = HotKeyMonitor(
            onDown: { [weak self] in
                MainActor.assumeIsolated { self?.handlePushToTalkStart() }
            },
            onUp: { [weak self] in
                MainActor.assumeIsolated { self?.handlePushToTalkEnd() }
            }
        )
        guard monitor.start() else {
            lastError = "无法监听键盘事件，请在系统设置中开启「输入监控」权限"
            refreshStatusLine()
            return
        }
        self.monitor = monitor
        refreshStatusLine()
    }

    private func handlePushToTalkStart() {
        pipeline.notice("hotkey down: transcribing=\(self.isTranscribing, privacy: .public) recording=\(self.recorder.isRecording, privacy: .public)")
        guard !isTranscribing, !recorder.isRecording else { return }
        guard Permissions.hasMicrophone else {
            lastError = "缺少麦克风权限，无法录音"
            Permissions.requestMicrophone { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissionLine() }
            }
            refreshStatusLine()
            return
        }
        do {
            try recorder.start()
            lastError = nil
            statusNote = nil
            armAutoStop()
            refreshStatusLine(recording: true)
        } catch {
            lastError = "录音启动失败：\(error)"
            refreshStatusLine()
        }
    }

    private func handlePushToTalkEnd() {
        cancelAutoStop()
        guard recorder.isRecording else { return }
        do {
            let (url, duration) = try recorder.stop()
            guard duration >= Config.minimumRecordingSeconds else {
                try? FileManager.default.removeItem(at: url)
                lastError = nil
                refreshStatusLine()
                return
            }
            transcribeAndInsert(audioURL: url, duration: duration)
        } catch {
            lastError = "结束录音失败：\(error)"
            refreshStatusLine()
        }
    }

    private func armAutoStop() {
        cancelAutoStop()
        autoStopArmed = true
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: Config.maximumRecordingSeconds,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePushToTalkEnd() }
        }
    }

    private func cancelAutoStop() {
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        autoStopArmed = false
    }

    private func transcribeAndInsert(audioURL: URL, duration: TimeInterval) {
        isTranscribing = true
        autoStopArmed = false
        refreshStatusLine()

        Task {
            do {
                let started = Date()
                let text = try await transcriber.transcribe(
                    audioURL: audioURL,
                    language: Config.language
                )
                pipeline.notice("transcribed: chars=\(text.count, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public)s")
                let polished = await polishIfNeeded(text)
                finish(text: polished, duration: duration)
            } catch {
                pipeline.error("transcribe failed: \(String(describing: error), privacy: .public)")
                isTranscribing = false
                lastError = "识别失败：\(error)"
                refreshStatusLine()
            }
        }
    }

    private func polishIfNeeded(_ text: String) async -> String {
        let mode = Config.polishMode
        guard mode != .off, !text.isEmpty else {
            statusNote = nil
            lastSource = text
            lastPolished = nil
            refreshCompareItem()
            return text
        }
        isPolishing = true
        refreshStatusLine()
        let started = Date()
        let result = await polisher.polish(text, mode: mode)
        isPolishing = false
        pipeline.notice("polished: mode=\(mode.rawValue, privacy: .public) in=\(text.count, privacy: .public) out=\(result.text.count, privacy: .public) in \(Date().timeIntervalSince(started), privacy: .public)s note=\(result.note ?? "-", privacy: .public)")
        statusNote = result.note
        lastSource = text
        lastPolished = result.text
        refreshCompareItem()
        return result.text
    }

    private func refreshCompareItem() {
        compareItem?.isEnabled = lastSource != nil
    }

    /// 把上一轮的原文和最终插入内容并排摊开，方便判断整理到底帮了忙还是帮倒忙。
    @objc private func showLastComparison() {
        guard let source = lastSource else { return }
        NSApp.activate(ignoringOtherApps: true)

        let inserted = lastPolished ?? source
        var body = "识别原文（\(source.count) 字）\n\(source)\n\n插入的文字（\(inserted.count) 字）\n\(inserted)"
        if lastPolished == nil {
            body += "\n\n（这一轮没有整理，原文直接插入）"
        }
        if let statusNote {
            body += "\n\n备注：\(statusNote)"
        }

        let alert = NSAlert()
        alert.messageText = "上次结果对比"
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func finish(text: String, duration: TimeInterval) {
        isTranscribing = false
        guard !text.isEmpty else {
            pipeline.notice("finish: empty transcript, duration=\(duration, privacy: .public)s")
            lastError = "未识别到语音内容（\(duration.formatted(.number.precision(.fractionLength(1)))) 秒）"
            refreshStatusLine()
            return
        }

        let accessibility = Permissions.hasAccessibility
        let postEvents = Permissions.canPostEvents
        pipeline.notice("finish: chars=\(text.count, privacy: .public) accessibility=\(accessibility, privacy: .public) postEvents=\(postEvents, privacy: .public)")

        guard accessibility, postEvents else {
            copyToClipboard(text)
            Permissions.promptAccessibility()
            lastError = "缺少辅助功能权限，文本已复制到剪贴板"
            refreshStatusLine()
            return
        }

        // 投递可能被系统静默丢弃（安全输入框、非标准输入控件等），
        // 这时绝不能既没插进去又不留后路，一律补一次剪贴板。
        let inserted = TextInjector.insert(text)
        pipeline.notice("finish: insert result=\(inserted, privacy: .public)")
        if !inserted {
            copyToClipboard(text)
            lastError = "无法写入光标，文本已复制到剪贴板"
            refreshStatusLine()
            return
        }
        lastError = nil
        refreshStatusLine()
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
