import AppKit
import Foundation

/// 录音时在屏幕底部显示的浮动胶囊（参考 Typeless 的「正在聆听」指示）。
///
/// 两条硬约束决定了实现方式：
/// 1. **不能抢焦点**：录音结束后文字要贴回原来的输入框，窗口一旦获得焦点，
///    原应用就不再是前台了。所以用 `.nonactivatingPanel` + `ignoresMouseEvents`。
/// 2. **只做指示，不做交互**：点击「取消/完成」需要拦截事件（Typeless 用原生小帮手
///    去吞事件），这里不做——开始/结束仍然只由 Option+Command 触发，胶囊纯展示。
///
/// 预览：`VOICETYPE_PREVIEW_CAPSULE=1 open -a Voicetype` 会直接显示 5 秒，方便调样式。
@MainActor
final class ListeningCapsule {
    enum State: Equatable {
        case listening
        case transcribing
    }

    private let panel: NSPanel
    private let canvas: CapsuleCanvas
    private var hideWorkItem: DispatchWorkItem?

    init() {
        let size = CapsuleCanvas.preferredSize
        canvas = CapsuleCanvas(size: size)

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = canvas
        panel.alphaValue = 0
    }

    /// 麦克风电平 0…1，调用方可以高频调用。
    func setLevel(_ level: Float) {
        canvas.targetLevel = CGFloat(max(0, min(1, level)))
    }

    func show(_ state: State) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        canvas.state = state
        reposition()
        if panel.alphaValue < 1 {
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWorkItem?.cancel()
        guard delay > 0 else { fadeOut(); return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func fadeOut() {
        guard panel.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
        }
    }

    /// 跟随鼠标所在屏幕，贴在可视区域底部（避开 Dock）。
    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = CapsuleCanvas.preferredSize
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 92
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

/// 胶囊的绘制层：半透明深色底 + 随音量跳动的波形 + 一行说明文字。
private final class CapsuleCanvas: NSView {
    static let preferredSize = NSSize(width: 108, height: 24)

    var targetLevel: CGFloat = 0

    var state: ListeningCapsule.State = .listening {
        didSet { if state != oldValue { needsDisplay = true } }
    }

    /// 每个柱子的相位偏移，让波形看起来自然而不是整齐划一。
    private let barPhases: [CGFloat] = [0.0, 0.55, 0.25, 0.8, 0.4]
    private var smoothed: [CGFloat]
    private var phase: CGFloat = 0
    private var timer: Timer?

    init(size: NSSize) {
        smoothed = Array(repeating: 0.12, count: 5)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        startAnimating()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { timer?.invalidate() }

    private func startAnimating() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        phase += 0.14
        for index in smoothed.indices {
            // 目标值 = 音量 × 每根柱子的固定权重，再叠一点相位摆动模拟真实频谱。
            let weight = 0.55 + 0.45 * abs(sin(phase * 0.6 + barPhases[index] * .pi))
            let target = state == .listening
                ? max(0.10, targetLevel * weight)
                : 0.10
            // 上升快、回落慢，观感更接近电平表。
            let factor: CGFloat = target > smoothed[index] ? 0.45 : 0.12
            smoothed[index] += (target - smoothed[index]) * factor
        }
        if state == .listening || targetLevel > 0 || smoothed.contains(where: { $0 > 0.12 }) {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let capsule = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = capsule.height / 2

        // 底：深色半透明，带一层很轻的描边，保证在浅色桌面上也有轮廓。
        let path = NSBezierPath(roundedRect: capsule, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.11, alpha: 0.86).setFill()
        path.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.10).setStroke()
        path.lineWidth = 1
        path.stroke()

        // 波形
        let barWidth: CGFloat = 2
        let gap: CGFloat = 2
        let totalWidth = CGFloat(smoothed.count) * barWidth + CGFloat(smoothed.count - 1) * gap
        let wavesLeft: CGFloat = 10
        let midY = capsule.midY
        let maxHeight = capsule.height - 9

        for (index, level) in smoothed.enumerated() {
            let height = max(2, maxHeight * level)
            let rect = NSRect(
                x: wavesLeft + CGFloat(index) * (barWidth + gap),
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
            let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            let isRecording = state == .listening
            let color = isRecording
                ? NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.35, alpha: 0.95)
                : NSColor(calibratedWhite: 0.72, alpha: 0.85)
            color.setFill()
            bar.fill()
        }

        // 文字
        let text: String
        switch state {
        case .listening: text = "正在聆听"
        case .transcribing: text = "正在识别…"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 0.92),
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let textOrigin = NSPoint(
            x: wavesLeft + totalWidth + 8,
            y: midY - textSize.height / 2
        )
        attributed.draw(at: textOrigin)
    }
}
