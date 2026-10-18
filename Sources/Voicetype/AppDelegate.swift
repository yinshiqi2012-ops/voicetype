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
    private let capsule = ListeningCapsule()
    private let polisher = SpeechPolisher()
    private let usage = UsageStats()
    private var monitor: HotKeyMonitor?

    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var hintLine: NSMenuItem?
    private var permissionLine: NSMenuItem?
    private var loginItemMenu: NSMenuItem?
    private var polishModelLine: NSMenuItem?
    private var polishModeItems: [PolishMode: NSMenuItem] = [:]
    private var compareItem: NSMenuItem?
    private var usageMenu: NSMenuItem?
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
    /// 本轮录音观察到的最大电平，用于确认麦克风数据确实驱动到了胶囊。
    private var peakLevel: Float = 0
    /// 是否加载过 ggml（transcribe.cpp）权重，决定退出时要不要绕过静态析构。
    private var ggmlModelLoaded = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 调试口要先跑：它只读或写统计文件，不该顺手把正在运行的实例关掉。
        handleDebugHooks()
        // 双开会让两个进程同时抓 Option+Command，各录一遍、各插一遍，
        // 表现就是"同一句话出来两段差不多的文字"。新进程负责收掉旧进程。
        enforceSingleInstance()
        setUpStatusItem()
        setUpHotKey()
        requestMissingPermissions()
        warmUpModel()
        warmUpPolisher()
        wireCapsule()

        if ProcessInfo.processInfo.environment["VOICETYPE_PREVIEW_CAPSULE"] == "1" {
            capsule.show(.listening)
            capsule.hide(after: 5)
        }

        // 文档截图用：自动弹出菜单，外部截完图按 Esc 关闭后进程即退出。
        if ProcessInfo.processInfo.environment["VOICETYPE_PREVIEW_MENU"] == "1" {
            Task { [weak self] in
                // 等模型和 Ollama 状态都确定下来再弹菜单，截图里才不会出现"准备中/检查中"。
                for _ in 0..<60 {
                    guard let self, !self.isModelReady else { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if let self {
                    let line = await self.polisher.statusLine()
                    self.polishModelLine?.title = line
                    self.refreshStatusLine()
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, let button = self.statusItem?.button else { return }
                // 走 button.performClick 而不是 NSMenu.popUp：后者在非活跃应用里
                // 会立刻被系统收掉，截不到图。performClick 等价于真实鼠标点击菜单栏图标。
                // 激活动作会合成一个 flagsChanged，可能被当成 Option+Command 触发录音。
                // 截图流程里先停掉监听，避免菜单状态显示成"正在录音"。
                self.monitor?.stop()
                self.monitor = nil
                NSApp.activate(ignoringOtherApps: true)
                button.performClick(nil)
                // 菜单被 Esc 关掉后走到这里；用 _exit 跳过 ggml 静态析构。
                _exit(0)
            }
        }
    }

    /// 让最新启动的进程独占运行，避免重复注入文本。
    private func enforceSingleInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let older = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() && $0.processIdentifier < getpid() }
        guard !older.isEmpty else { return }
        pipeline.notice("single instance: 关闭 \(older.count, privacy: .public) 个旧实例")
        for app in older { app.terminate() }
        // 热键监听要先等旧进程真的退出，否则两边会同时抢到事件。
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, older.contains(where: { !$0.isTerminated }) {
            usleep(50_000)
        }
    }

    /// 命令行调试口：不进菜单，只给排障用。
    private func handleDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["VOICETYPE_DEBUG_RECORD"], let chars = Int(raw) {
            usage.record(chars: chars)
            print(usageSummary())
            exit(0)
        }
        if env["VOICETYPE_PRINT_USAGE"] == "1" {
            print(usageSummary())
            exit(0)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelAutoStop()
        monitor?.stop()
        // ggml-metal 要求退出前释放 GPU 资源。先把权重放掉，最多等 1 秒。
        let released = DispatchSemaphore(value: 0)
        Task {
            await transcriber.unload()
            released.signal()
        }
        _ = released.wait(timeout: .now() + 1)

        // 已加载过 ggml 权重时，正常 exit 会在 C++ 静态析构里断言
        // `GGML_ASSERT([rsets->data count] == 0) failed` → 进程 abort、每次退出留一份崩溃报告。
        // 该断言发生在静态析构阶段，Swift 侧无法补救，只能跳过析构直接结束进程。
        // 统计文件每笔都是原子写、识别结果此刻已全部落盘，_exit 不会丢数据。
        if ggmlModelLoaded {
            pipeline.notice("terminate: 跳过 ggml 静态析构，避免 Metal 断言")
            _exit(0)
        }
    }

    // MARK: - 菜单栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "voicetype")
        item.button?.toolTip = "voicetype：按 Option+Command 开始/结束说话"

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

        let usageItem = NSMenuItem(title: "用量统计", action: nil, keyEquivalent: "")
        usageItem.submenu = NSMenu()
        menu.addItem(usageItem)
        usageMenu = usageItem
        rebuildUsageMenu()

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
            state = "正在录音…（再按 Option+Command 结束）"
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
            state = "就绪，按 Option+Command 说话"
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
                ggmlModelLoaded = Config.asrEngine.usesGGML
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
        case .off: "按 Option+Command 说话，再按一次即转写并插入"
        case .clean: "按 Option+Command 说话，再按一次整理并插入"
        case .summary: "按 Option+Command 说话，再按一次总结并插入"
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
                ggmlModelLoaded = Config.asrEngine.usesGGML
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
        rebuildUsageMenu()
        Task {
            let line = await polisher.statusLine()
            polishModelLine?.title = line
        }
    }

    // MARK: - 热键

    private func setUpHotKey() {
        let monitor = HotKeyMonitor { [weak self] in
            MainActor.assumeIsolated { self?.handleHotKeyToggle() }
        }
        guard monitor.start() else {
            lastError = "无法监听键盘事件，请在系统设置中开启「输入监控」权限"
            refreshStatusLine()
            return
        }
        self.monitor = monitor
        refreshStatusLine()
    }

    /// Option+Command 每按一次调用一次：没在录音就开始，正在录音就结束。
    private func handleHotKeyToggle() {
        pipeline.notice("hotkey toggle: recording=\(self.recorder.isRecording, privacy: .public) transcribing=\(self.isTranscribing, privacy: .public)")
        if recorder.isRecording {
            finishRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // 上一轮的识别/整理还没结束时忽略本次触发，避免串轮。
        guard !isTranscribing else { return }
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
            peakLevel = 0
            capsule.setLevel(0)
            capsule.show(.listening)
        } catch {
            lastError = "录音启动失败：\(error)"
            refreshStatusLine()
        }
    }

    private func finishRecording() {
        cancelAutoStop()
        guard recorder.isRecording else { return }
        do {
            let (url, duration) = try recorder.stop()
            guard duration >= Config.minimumRecordingSeconds else {
                try? FileManager.default.removeItem(at: url)
                capsule.hide()
                lastError = nil
                refreshStatusLine()
                return
            }
            capsule.show(.transcribing)
            transcribeAndInsert(audioURL: url, duration: duration)
        } catch {
            capsule.hide()
            lastError = "结束录音失败：\(error)"
            refreshStatusLine()
        }
    }

    /// 把麦克风电平接到胶囊上；回调来自音频线程，这里切回主线程。
    private func wireCapsule() {
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.peakLevel = max(self.peakLevel, level)
                    self.capsule.setLevel(level)
                }
            }
        }
    }

    private func armAutoStop() {
        cancelAutoStop()
        autoStopArmed = true
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: Config.maximumRecordingSeconds,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRecording() }
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
                capsule.hide()
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
        capsule.hide()
        guard !text.isEmpty else {
            pipeline.notice("finish: empty transcript, duration=\(duration, privacy: .public)s")
            lastError = "未识别到语音内容（\(duration.formatted(.number.precision(.fractionLength(1)))) 秒）"
            refreshStatusLine()
            return
        }

        // 只要产生了输出就计入统计（插入成功或退化成剪贴板都算）。
        usage.record(chars: text.count)

        let accessibility = Permissions.hasAccessibility
        let postEvents = Permissions.canPostEvents
        pipeline.notice("finish: chars=\(text.count, privacy: .public) peakLevel=\(self.peakLevel, privacy: .public) accessibility=\(accessibility, privacy: .public) postEvents=\(postEvents, privacy: .public)")

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

    // MARK: - 用量统计

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 菜单每次展开都重算，保证数字是"打开这一刻"的实时值。
    private func rebuildUsageMenu() {
        guard let submenu = usageMenu?.submenu else { return }
        let hour = usage.chars(inLast: 3600)
        let rollingDay = usage.chars(inLast: 24 * 3600)
        let today = usage.todayChars
        let week = usage.chars(lastDays: 7)
        let month = usage.chars(lastDays: 30)
        let total = usage.totalChars

        submenu.removeAllItems()
        submenu.addItem(infoItem("最近 1 小时：\(UsageStats.format(hour)) 字"))
        submenu.addItem(infoItem("最近 24 小时：\(UsageStats.format(rollingDay)) 字"))
        submenu.addItem(infoItem("今天：\(UsageStats.format(today)) 字"))
        submenu.addItem(infoItem("近 7 天（按自然日）：\(UsageStats.format(week)) 字"))
        submenu.addItem(infoItem("近 30 天（按自然日）：\(UsageStats.format(month)) 字"))
        submenu.addItem(infoItem("历史累计：\(UsageStats.format(total)) 字"))

        // 每日明细：最近 14 天，够看出习惯也能塞进菜单。
        submenu.addItem(.separator())
        let daily = NSMenuItem(title: "每日明细（近 14 天）", action: nil, keyEquivalent: "")
        let dailyMenu = NSMenu()
        for row in usage.dailyTotals(lastDays: 14) {
            let label = UsageStats.dayLabel(for: row.date)
            dailyMenu.addItem(infoItem("\(label)　\(UsageStats.format(row.chars)) 字"))
        }
        daily.submenu = dailyMenu
        submenu.addItem(daily)

        submenu.addItem(.separator())
        let copy = NSMenuItem(title: "复制统计摘要", action: #selector(copyUsageSummary), keyEquivalent: "")
        copy.target = self
        submenu.addItem(copy)

        usageMenu?.title = "用量统计：今天 \(UsageStats.format(today)) 字"
    }

    @objc private func copyUsageSummary() {
        copyToClipboard(usageSummary())
        lastError = nil
        statusNote = "统计摘要已复制到剪贴板"
        refreshStatusLine()
    }

    /// 纯文本摘要，菜单复制和命令行调试共用同一份格式。
    private func usageSummary() -> String {
        let stamp = Date().formatted(date: .numeric, time: .shortened)
        var lines = [
            "voicetype 输出字数统计",
            "统计时间：\(stamp)",
            "最近 1 小时：\(UsageStats.format(usage.chars(inLast: 3600))) 字",
            "最近 24 小时：\(UsageStats.format(usage.chars(inLast: 24 * 3600))) 字",
            "今天：\(UsageStats.format(usage.todayChars)) 字",
            "近 7 天（按自然日）：\(UsageStats.format(usage.chars(lastDays: 7))) 字",
            "近 30 天（按自然日）：\(UsageStats.format(usage.chars(lastDays: 30))) 字",
            "历史累计：\(UsageStats.format(usage.totalChars)) 字",
            "",
            "每日明细（近 14 天）：",
        ]
        for row in usage.dailyTotals(lastDays: 14) {
            lines.append("\(UsageStats.dayLabel(for: row.date))　\(UsageStats.format(row.chars)) 字")
        }
        return lines.joined(separator: "\n")
    }
}
