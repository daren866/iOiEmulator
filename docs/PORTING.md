# 移植状态与路线图

> **先说清楚**：本仓库的 GitHub Actions 流水线能真实产出一个**可安装、未签名、arm64 的 iOS App**，
> 但这个 IPA 目前是**应用外壳 + 移植脚手架**，**尚未包含可运行的 qemu-ios 模拟器**。
> 把 LightTouch / qemu-ios 真正跑进 iOS 是一次独立的、数周量级的移植，不是改一个 YAML 就能完成的。
> 本文记录已完成的部分、未完成的部分，以及可执行的路线，避免把脚手架误当成成品。

## 1. 状态表

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| Tuist 工程（重命名、iOS 15.0、无签名设置） | ✅ 完成 | `Project.swift` |
| SwiftUI 外壳（状态 / 设备目录 / 侧载说明） | ✅ 完成 | `iOiEmulator/` |
| 引擎抽象层与显示表面占位 | ✅ 完成 | `iOiEmulator/Engine/` |
| GitHub Actions：提交即构建未签名 IPA | ✅ 完成 | `.github/workflows/build-unsigned-ipa.yml` |
| GitHub Actions：IPA 自动上传 Releases | ✅ 完成 | 每次 push 生成 `build-N` prerelease |
| 引擎源码锁定 + 校验下载 | ✅ 完成 | `engine/SOURCES.json`、`scripts/fetch-engine.sh` |
| iOS 交叉编译配方（草案） | ⚠️ 草案 | `scripts/build-engine-ios.sh`，未经真机验证 |
| qemu-ios 设备模型 rebase 到 iOS-host QEMU | ❌ 未做 | 见第 3 节步骤 1 |
| 依赖库 iOS 化 / framework 打包 | ❌ 未做 | 见第 3 节步骤 2 |
| host GL / 触摸 / 传感器 / 音频接入 | ❌ 未做 | 见第 3 节步骤 3 |
| helper 进程单进程化 | ❌ 未做 | 见第 3 节步骤 4 |
| IPSW 制备与 NAND 导入 | ❌ 未做 | 见第 3 节步骤 5 |
| `QemuEngineBridge` 实现并链接 | ❌ 未做 | 见第 3 节步骤 6 |

## 2. 可行性依据（来自上游自己的研究）

`qemu-ios` 源码包内 `docs/research/ipod-touch-2g-on-iphone.md`（2026-08-03）明确写着
**"Verdict: viable"**，同时注明 **"nothing was built from it"**。关键实测数据：

| 指标 | 有 JIT | TCI 解释器（无 JIT） |
| --- | ---: | ---: |
| 开机 wall clock | 39.0 s / 24.7 s | 115.9 s |
| 开机 CPU-seconds | 30.89 / 19.37 | 101.58 |
| 交互占用单核 | 6.5–10.9 % | ~22 %（idle 数据受干扰，以 driven 15 % 为准） |
| 实测损失 | — | **3.3–5.2×**（TCI；UTM SE 的 TCTI 更快，约 4× 为上限） |

换算到手机：A19 Pro 单核约 0.90 个 M4 Max 核心，持续降频约 0.75，合计约 **0.68 M4-Max-core-equivalent**。
无 JIT 开机约 2 分 50 秒、交互约 22 % 单核，两者都在可用范围。
且引擎已具备 `migrate file:` + `-incoming file:` 快照（86 MB / 1.1 s），
**可以预置开机后快照，让用户完全跳过启动**。

结论：**速度不是阻碍**。真正的阻碍是 JIT 的获取方式，以及下面第 4 节的合规问题。

## 3. 移植六步（可执行的工程路线）

### 步骤 1 · rebase 到带 iOS host 支持的 QEMU

本 fork 基于 **QEMU 8.2.0**；UTM 维护的 iOS-host QEMU 是 **10.0.2**
（Joelle van Dyne 的 `iOS and Apple Silicon host support` 补丁集，qemu-devel 2021-01）。
迁移需要把 `hw/arm/` 下的设备模型搬到 `utmapp/qemu`。

好消息：`git diff --shortstat v8.2.0 HEAD` 为 **170 文件 / +29657 / -214 行**，
几乎纯增量；`tcg/`、`accel/`、`target/arm/` **一行未改**，所以 rebase 与替换 TCG 后端风险低。
上游被改动的文件只有 `hw/dma/pl080.c`、`hw/char/exynos4210_uart.c`、
`ui/sdl2.c` 一行、`include/qemu/osdep.h` 一行。

### 步骤 2 · 依赖库交叉编译

需要全部编成 iOS arm64 静态库并打包为 `.framework`（iOS 不允许裸 dylib 随意加载）：

- GLib、pixman、libslirp、PCRE2、OpenSSL
- FFmpeg（必须带 `--enable-encoder=aac`，否则 Voice Memos / AMC 编码器缺失）
- libplist、libusbmuxd、libimobiledevice、libtatsu

可直接复用 UTM 的 `scripts/build_dependencies.sh -p ios-tci -a arm64` 产物与
`--disable-cocoa --disable-coreaudio --disable-slirp-smbd --enable-ucontext` 配置组合。
`scripts/build-engine-ios.sh` 已生成 Meson cross file 与 configure 配方草案。

### 步骤 3 · host 层适配

| 项 | 结论 | 工作量 |
| --- | --- | --- |
| 图形 | **iOS 比 macOS 更合适**：`OpenGLES.framework` 仍导出 457 个 GL 入口，含完整固定功能管线，正是 guest 的 GLES 1.1。只需把 `hw/arm/gles-host.c` 的 CGL 段（~40 行）换成 `EAGLContext`，`*EXT` FBO 后缀改 `*OES`。**不需要 Metal 转译** | 小 |
| 触摸 | `ipod_touch_lcd_mouse_event()` 已接收归一化坐标，UIKit handler 直接调用三个多点函数即可 | 近乎免费 |
| 多点触控 | **引擎未实现**（只有单指 `FingerData`），需要补；wire header 已有 `numFingers` / `fingerDataLen` | 中 |
| 加速度计 | LIS302DL 已建模，`ACCEL_1G = 0x40`；X 轴与 UIKit 相反：`x = -a.x*0x40`。注意要抑制 `lis302dl_apply_orientation()` 里的 host 窗口旋转 | 近乎免费 |
| 音频输出 | host 路径已验证，但 guest 未启动传输，有未修 bug | 中 |
| 麦克风 | `hw/arm/` 里完全没有 `AUD_open_in` / `SWVoiceIn` / `AUD_read`，两个 codec 模型也没有 mic 寄存器 | 大 |

### 步骤 4 · 单进程化（App 壳层最大改动）

LightTouch 桌面/Android 版依赖大量独立 helper 进程：
`usbmuxd` daemon、`LightTouchServices`、`firmwarekit`（Android 上以 `libfirmwarekit.so` 被 App 启动）、
`GuestAgent` 等。**iOS 不允许 App `fork`/`exec` 子进程**，这些都得改成进程内线程 + 静态库调用。
`qemu-ios` 本身从设计上就是库（macOS 为 `libqemu-arm.dylib`、Android 为 `libqemu-arm.so`），这部分反而好办。

### 步骤 5 · 固件制备

两个源码包都**不含 Apple 固件**。桌面版流程是：下载 IPSW → 校验 → 解密 → patch iBoot/内核 →
构建 NAND/NOR → 生成 `.itbase`。在 iOS 上有三条路：

1. 在受控环境预先制备好，用户通过 **Files App 导入**（`Info.plist` 已开 `UIFileSharingEnabled`）；
2. 把 Rust 写的 `firmwarekit` 交叉编译到 iOS，在设备上制备（需处理几 GB 下载与内存压力）；
3. 随 App 附带**开机后快照**，配合 `migrate file:` 恢复，跳过 NAND 制备与启动。

**任何情况下都不要把 Apple 固件或解密组件放进仓库、CI 缓存或 IPA。**

### 步骤 6 · 链接与桥接

把 `libqemu-arm` 做成 framework，接入 `Tuist/Package.swift`，实现
`iOiEmulator/Engine/EmulatorEngine.swift` 的 `QemuEngineBridge`，把 `DisplaySurface`
blit 到 `EngineHostView`（当前是占位 UIView）。

上游估算：**熟悉 iOS 构建的人做最小验证约 1–2 周**（rebase + bundle 内放 NAND/NOR/bootrom +
blit + 测有/无 JIT 开机）；完整产品化是数月量级。风险集中在 rebase，不在 App 本身。

## 4. JIT 与分发限制（为什么只做自用侧载）

| 路径 | 状态 |
| --- | --- |
| App Store 分发 | ❌ 基本不可能：审核指南 2.5.2（不得下载/执行改变功能的代码）、4.7 只放行复古游戏主机模拟器；解密 Apple 固件、patch 内核、内置 jailbreak 开关均触线 |
| GPL-2.0 与 App Store | ⚠️ QEMU / qemu-ios 为 GPL-2.0，与 App Store 条款存在已知冲突（2011 年 VLC 下架先例，FSF 认定 GPLv2 §6 被违反） |
| 无 JIT（TCI / TCTI） | ✅ 可用，约 3.3–5.2× 减速，是本工作流的默认目标 |
| StikDebug 开 JIT | ⚠️ iOS 17.4–26.x，`get-task-allow` + `ptrace(PT_TRACE_ME)` 置 `CS_DEBUGGED`；需要设备配对文件、**每次启动重新挂载**、免费证书 7 天（或 $99/年），随 iOS 更新易失效 |
| TrollStore | ⚠️ 仅限 iOS 14.0–16.6.1 / 17.0；CoreTrust 漏洞在 17.0.1 已修补，新系统不再可装 |
| EU 浏览器引擎 entitlement | ❌ 不适用于模拟器 |

**结论**：TrollStore / AltStore+StikDebug / Sideloadly 自签 / 企业内部分发是现实路径；
本仓库产出的未签名 IPA 就是为这些渠道准备的。

## 5. 参考

- `qemu-ios` 包内 `docs/research/ipod-touch-2g-on-iphone.md`（可行性研究，含上表全部实测数据）
- [LightTouch v0.0.13 Release](https://github.com/blake-lucas/LightTouch/releases/tag/v0.0.13)
- [blake-lucas/qemu-ios](https://github.com/blake-lucas/qemu-ios) · [utmapp/qemu](https://github.com/utmapp/qemu)
- [QEMU patch v9: iOS and Apple Silicon host support](https://lists.gnu.org/archive/html/qemu-devel/2021-01/msg06490.html)
- [TCTI: JITless AArch64 TCG backend](https://patchwork.ozlabs.org/project/qemu-devel/cover/20250722174228.16205-1-j@getutm.app/)
- [Apple: Porting JIT compilers to Apple silicon](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)
