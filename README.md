# iOiEmulator

自用 / 侧载向的 **未签名 iOS arm64 IPA** 工程。目标是把
[LightTouch](https://github.com/blake-lucas/LightTouch) / [qemu-ios](https://github.com/blake-lucas/qemu-ios)
（在 Android、Linux、Windows、macOS 上模拟 2007–2011 年经典 iPhone / iPod touch / iPad，
运行 iPhone OS 1 – iOS 7 原厂固件）移植到 iOS 设备上运行。

> ## ⚠️ 当前状态：脚手架，不是成品
>
> GitHub Actions 会真实产出**可安装的未签名 IPA**，但这个 IPA 目前只包含
> **应用外壳 + 移植脚手架**，**还没有链接 qemu-ios 引擎，不能启动 iOS 客户机**。
> 真正的引擎移植是一次独立的数周量级工程，详见 [`docs/PORTING.md`](docs/PORTING.md)。
> 请勿把本仓库的 IPA 误认为"已经能在 iPhone 上跑 iOS 的模拟器"。

## 已落地

- **提交即构建**：任意分支有新 push 自动触发；`workflow_dispatch` 可手动触发。
- **未签名 arm64 IPA**：Tuist 生成工程 → `xcodebuild archive` 关闭代码签名 →
  `Payload/` 打包 → `ldid` 可选 ad-hoc 伪签名 → `SHA256SUMS`。
- **自动上传 Releases**：每次成功构建发布一个 `build-N` prerelease，
  附 IPA、校验值、构建信息。使用 `GITHUB_TOKEN`，无需配置 PAT。
- **引擎源码锁定**：`engine/SOURCES.json` 记录两个 tarball 的 SHA256（已实测核对），
  `scripts/fetch-engine.sh` 可校验下载。
- **iOS 侧抽象层**：`EmulatorEngine` 协议、8 块板子目录、`EngineHostView` 显示表面占位。
- **交叉编译配方草案**：`scripts/build-engine-ios.sh` 生成 Meson cross file 与 configure 配方。

## 快速开始

### 拿 IPA

去本仓库 **Releases** 下载最新的 `iOiEmulator_unsigned_arm64_*.ipa`，
用 `SHA256SUMS` 校验后安装：

| 方式 | 说明 |
| --- | --- |
| TrollStore | iOS 14.0–16.6.1 / 17.0，IPA 已做 ad-hoc 伪签名，直接导入 |
| AltStore / SideStore | 用自己的 Apple ID 证书重签后安装（免费证书 7 天） |
| Sideloadly / 爱思助手 | 用自己的开发证书重签后安装 |

### 本地构建（macOS + Xcode）

```bash
brew install tuist ldid
just generate
just archive-unsigned
```

CI 端完整说明见 [`docs/CI.md`](docs/CI.md)。

### 拉引擎源码

```bash
GH_PROXY=https://v4.gh-proxy.org/ bash scripts/fetch-engine.sh
```

下载结果在 `engine/vendor/`（已被 `.gitignore` 忽略），SHA256 会逐一校验。

## 移植路线（摘要）

完整版见 [`docs/PORTING.md`](docs/PORTING.md)，六步：

1. 把 qemu-ios（QEMU 8.2.0 fork）的设备模型 rebase 到 UTM 的 `utmapp/qemu`（10.0.2，含 iOS host 补丁）
2. GLib / pixman / libslirp / PCRE2 / OpenSSL / FFmpeg / libimobiledevice 全家桶交叉编译并打包成 framework
3. `hw/arm/gles-host.c` 的 CGL → `EAGLContext`（约 40 行），接入触摸 / 加速度计 / 音频
4. helper 进程单进程化（iOS 禁止 `fork`/`exec`）
5. IPSW 制备 / NAND 导入（固件不入库、不入 CI、不入 IPA）
6. 链接 `libqemu-arm`，实现 `QemuEngineBridge`，把 `DisplaySurface` blit 到 `EngineHostView`

上游自己的可行性研究（`qemu-ios` 包内 `docs/research/ipod-touch-2g-on-iphone.md`，2026-08-03）
结论是 **viable**：无 JIT 的 TCI 解释器实测只慢 **3.3–5.2×**，
A19 Pro 上交互约 22 % 单核；配合 `migrate file:` 快照可跳过约 2 分 50 秒的冷启动。
**速度不是障碍**，JIT 获取方式与审核合规才是。

## 目录

```
.github/workflows/build-unsigned-ipa.yml   # 提交即构建 + 自动发布 Releases
Project.swift / Tuist.swift / Tuist/       # Tuist 工程定义
iOiEmulator/                              # SwiftUI 外壳 + Engine 抽象层
engine/SOURCES.json                       # 引擎源码锁定清单
scripts/fetch-engine.sh                   # 校验下载引擎源码
scripts/package-ipa.sh                    # IPA 打包（CI / 本地共用）
scripts/build-engine-ios.sh               # iOS 交叉编译配方（草案）
docs/PORTING.md                           # 移植状态与路线图
docs/CI.md                                # 工作流说明
NOTICE.md                                 # GPL / 固件 / 模板署名
```

## 许可与边界

- 本仓库自有代码 MIT；**引擎是 GPL-2.0**，链接后整体须遵守 GPL，见 [`NOTICE.md`](NOTICE.md)。
- 不含任何 Apple 固件、解密组件或制备好的设备镜像。
- **仅限自用侧载**。上架 App Store 受审核指南 2.5.2 / 4.7、Apple 固件版权、
  GPLv2 与 App Store 条款冲突三重限制，本项目不以此为目标。
- 与 Apple Inc. 无关联。
