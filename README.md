# voicetype

**按一下 Option+Command 说话，再按一下，整理好的文字就落在光标处。**

一个 macOS 菜单栏语音输入工具：语音识别和文本整理**全部在本机完成**，音频和文字都不出网，不需要账号、订阅或任何 API key。

[English](#english) · [安装](#安装) · [用哪套模型](#用哪套模型) · [实测数据](#实测数据) · [排障](#排障)

---

## 它是什么

- **全本机**：识别用 [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)（ggml）跑 Qwen3-ASR，整理用 [Ollama](https://ollama.com) 跑本地小模型。网络只在**首次下载模型**时用到。
- **按一下开始、再按一下结束**：热键是 Option+Command，不占用单键，也不和输入法打架。
- **文字直接写进光标处**：走 CGEvent，不抢焦点、不切窗口；投递失败会退化为复制到剪贴板，绝不丢话。
- **会整理，不照抄**：默认删口头禅、重复和改口，补标点。「插入原文」和「总结成要点」也在菜单里可以切换。
- **有事实兜底**：整理结果里数字或时间被改写/丢失时，直接回退原文——宁可不动，不能改错。
- **录音时有指示**：屏幕底部出现一个小胶囊，波形跟着你的音量跳动（静音时也有一道呼吸波形，不会看起来像卡死）。
- **字数统计**：菜单栏「用量统计」实时显示最近 1 小时 / 24 小时 / 今天 / 近 7 天 / 近 30 天 / 历史累计，附近 14 天每日明细，可一键复制摘要。
- **菜单栏常驻**，没有 Dock 图标，不打断工作。

## 安装

### 从源码构建（推荐）

需要 macOS 14+、Xcode Command Line Tools（Swift 6）。**不需要装 cmake**——原生推理库已随仓库提供。

```bash
git clone https://github.com/yinshiqi2012-ops/voicetype.git
cd voicetype
./scripts/build-app.sh
open dist/Voicetype.app
# 或装到 Applications：
cp -R dist/Voicetype.app /Applications/ && open /Applications/Voicetype.app
```

### 授权（必须）

首次启动后到「系统设置 → 隐私与安全性」里打开这三项，然后**重启应用**：

| 权限 | 用途 | 缺失后果 |
|---|---|---|
| 麦克风 | 录音 | 完全无法录音 |
| **输入监控** | 监听 Option+Command | 热键无反应 |
| **辅助功能** | 把文字投递到光标处 | 退化为复制到剪贴板 |

> ⚠️ 应用使用自签名证书（`Voicetype Dev`）。重新构建后如果权限失效，先在辅助功能列表里把 voicetype 移除，再重新添加。
> 想避免反复授权，可先运行一次 `./scripts/create-signing-cert.sh` 生成稳定的本地证书。

### 可选：把整理打开

不装 Ollama 也能用——只是变成"纯转写"。想要整理：

```bash
brew install ollama          # 或从 ollama.com 下载
ollama pull qwen3.5:9b       # 约 6.6GB，中文整理效果好
```

应用会自己在 `127.0.0.1:11434` 找到它；模型常驻内存后，整理一句约 0.4–1.9 秒。

## 用哪套模型

菜单栏 →「识别模型」可随时切换，切换是热加载，不用重启：

| 引擎 | 权重 | 内存占用 | 中文 CER ↓ | 35s 音频耗时 |
|---|---|---|---|---|
| **Qwen3-ASR 0.6B**（默认） | 811MB | ~1.5GB | **7.57%** | 574ms |
| Qwen3-ASR 1.7B | 2.0GB | ~3.1GB | 7.14% | 978ms |
| Whisper small（回退） | 467MB | ~240MB | 23.06% | ~1.6s |

中文 CER 取自 transcribe.cpp 官方 catalog 的 `fleurs-zh`（945 条，Q8_0，越低越好）。

模型不会打包进仓库，首次选择时自动下载，并从下列端点依次回退：

```
hf-mirror.com → huggingface.co
```

也可以用 `modelEndpoint` 覆盖：

```bash
defaults write com.truman.voicetype modelEndpoint "https://huggingface.co"
```

## 实测数据

**官方基准**（`fleurs-zh`，945 条）：

| 模型 | 参数 | 中文 CER |
|---|---|---|
| qwen3-asr-1.7b | 2.04B | 7.14% |
| **qwen3-asr-0.6b** | 782M | **7.57%** |
| whisper-large-v3 | 1.54B | 7.98% |
| breeze-asr-25（中英混说专用） | 1.54B | 8.10% |
| whisper-large-v3-turbo | 809M | 8.50% |
| fun-asr-nano-2512 | 830M | 8.59% |
| sensevoice-small | 234M | 10.12% |
| **whisper-small（本应用旧默认）** | 242M | **23.06%** |

**自己录的 6 条口述**（说话带口头禅和改口，同一引擎跑两个模型）：

| 案例 | Qwen3-ASR 0.6B | Whisper small |
|---|---|---|
| "拷给你" | ✅ 拷 | ❌ 考 |
| "真人说话" | ✅ 真人 | ❌ 证人 |
| "手搓了一个" / "要命" | ✅ 都对 | ❌ 手错 / 药密 |
| "没及时看见" | ✅ 没及时 | ❌ 没个机士 |
| "9B" / "zephyr4123" | ❌ 酒杯 / ZephY二四幺二三 | ✅ 都对 |
| "项下" | ❌ 人乡下 | ❌ 人相加 |

结论：**5:1，Qwen3-ASR 更准**，且它的错误是同音误听（一眼能看出），Whisper 的错误是替换和幻觉（读起来像真话，润色也救不回）。唯一劣势是英文+数字混排。

> 复现方法：`transcribe.cpp` 的 `transcribe-cli` 加载两个 GGUF，跑同一批 16kHz 单声道 WAV 即可，只有模型在变。

## 排障

| 症状 | 原因与处理 |
|---|---|
| 按 Option+Command 没反应 | 缺「输入监控」权限；授权后需重启应用 |
| 有识别结果但光标处没字 | 缺「辅助功能」权限；此时文字会进剪贴板 |
| 菜单栏是三角感叹号 | 菜单里那行「状态」写了具体原因 |
| 整理没生效 | Ollama 没运行，或没 `ollama pull` 对应模型；菜单「整理模型」那行会说明 |
| 识别很慢（十几秒） | 模型被换出内存。用 `ollama ps` 看常驻；整理模式设为「插入原文」则不加载 |
| 首次启动卡住 | 在下载模型（811MB 或 2.0GB），看菜单状态行 |
| 一句话出来两遍 | 同时开了两个实例（比如 `dist/` 里那份和 `/Applications` 那份）。打开新实例时会自动关掉旧的，日志里有 `single instance: 关闭 1 个旧实例` |
| 退出时弹「意外退出」 | 旧版本遗留；ggml 的 Metal 静态析构会断言，新版退出时跳过析构，不再产生崩溃报告 |

调试日志：

```bash
log show --predicate 'subsystem == "com.truman.voicetype"' --last 10m --style compact
```

会看到 `asr ready: engine=… → transcribed: chars=… → polished: … → finish: insert result=…` 全链路。

## 可配置项

```bash
defaults write com.truman.voicetype asrEngine   "qwen3-asr-0.6b"   # 或 qwen3-asr-1.7b / whisper-small
defaults write com.truman.voicetype polishMode  "clean"           # off / clean / summary
defaults write com.truman.voicetype polishModel "qwen3.5:9b"
defaults write com.truman.voicetype modelEndpoint "https://huggingface.co"
defaults write com.truman.voicetype language    ""                # 空 = 自动检测，默认固定 zh
```

字数统计可以命令行查看/清空：

```bash
# 直接打印统计（不启动界面）
/Applications/Voicetype.app/Contents/MacOS/voicetype  # 加环境变量 VOICETYPE_PRINT_USAGE=1
VOICETYPE_PRINT_USAGE=1 /Applications/Voicetype.app/Contents/MacOS/voicetype

# 清空统计
rm "~/Library/Application Support/voicetype/usage.json"
```

## 隐私

- 语音和文字**不离开本机**。唯一的网络请求是下载模型权重。
- 录音保存在 `~/Library/Application Support/voicetype/Recordings/`，不会自动清理。
- 整理请求发往 `127.0.0.1:11434`（本机 Ollama），不经过任何服务器。
- 字数统计只存在 `~/Library/Application Support/voicetype/usage.json`，是一份本地 JSON，不上报。

## 结构

```
Sources/Voicetype/
├── AppDelegate.swift        菜单栏、状态机、流程编排
├── HotKeyMonitor.swift      CGEventTap 监听 Option+Command
├── Recorder.swift           AVAudioEngine → 16kHz 单声道 WAV（含电平回调）
├── Transcriber.swift        识别引擎抽象：transcribe.cpp(Qwen3-ASR) / WhisperKit
├── ASREngine.swift          引擎与权重注册表
├── SpeechPolisher.swift     向本机 Ollama 请求整理
├── TranscriptCleanup.swift  整理提示词、输出清洗、数字/时间事实校验
├── TextInjector.swift       CGEvent 把文字写进光标
├── ListeningCapsule.swift   屏幕底部浮动胶囊
├── UsageStats.swift         输出字数统计（每日桶 + 48 小时明细，原子写盘）
├── Permissions.swift        三类系统权限
├── LoginItem.swift          开机自启
└── Config.swift             所有默认值与可覆盖项

Vendor/transcribe-cpp/       vendored 的 transcribe.cpp Swift 绑定（MIT）
scripts/build-app.sh         构建 .app（含框架嵌入与签名）
scripts/package-release.sh   打 zip 发布包
Tests/VoicetypeTests/        TranscriptCleanup 与 UsageStats 的单元测试
```

## 许可

MIT。第三方组件：

- [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) — MIT
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — MIT
- Qwen3-ASR 权重 — Apache-2.0（不随仓库分发）
- Ollama / qwen3.5 权重 — 各自许可（不随仓库分发）

---

## English

**A local-first dictation tool for macOS.** Press Option+Command, speak, press again — cleaned-up text lands at your cursor.

Everything runs on-device: speech recognition via [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) (ggml) with Qwen3-ASR, text cleanup via a local [Ollama](https://ollama.com) model. No account, no API key, no data leaving the machine. Network is used only to download model weights on first run.

**Requirements**: macOS 14+, Xcode Command Line Tools. No cmake needed — the native inference library ships with the repo.

```bash
./scripts/build-app.sh && open dist/Voicetype.app
```

Then grant **Microphone**, **Input Monitoring** and **Accessibility** in System Settings → Privacy & Security, and relaunch.

Chinese ASR accuracy (`fleurs-zh` CER): Qwen3-ASR 0.6B **7.57%** vs Whisper small **23.06%** — switchable in the menu, hot-reloaded.

Licensed under MIT.
