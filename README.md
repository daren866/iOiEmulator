# iOiEmulator

把 [qemu-ios / LightTouch](https://github.com/blake-lucas/LightTouch) 引擎移植进 **iOS arm64 App** 的自用侧载项目。

- **自动打包**：任意分支有新提交 → GitHub Actions 在 `macos-15`（Apple Silicon）上产出未签名 arm64 IPA → 自动发布到 [Releases](https://github.com/daren866/iOiEmulator/releases)
- **引擎移植**：拆成多个 macOS workflow（源码 → 依赖 → QEMU → IPA），可单独触发，也可一键串跑
- **无签名**：`CODE_SIGNING_ALLOWED=NO`，打包时用 `ldid -S` 做 ad-hoc 伪签名供 TrollStore
- **不含固件**：仓库、CI、IPA 均不含任何 Apple IPSW / NAND 镜像 / 解密组件

> ⚠️ **当前 IPA 默认是「应用外壳 + 移植脚手架」**。引擎编译流水线已搭好并在 CI 上真实执行，但 QEMU 能否完整编通、以及真机能否启动 guest，仍需按 `docs/PORTING.md` 验证。我没有拿 Hello World 冒充可运行的模拟器。

## 这两个源码包是什么

`engine/SOURCES.json` 锁定 LightTouch v0.0.13 的两个 tarball（SHA256 已与 Release 页核对）：

| | `qemu-ios-v0.0.13-source.tar.gz` | `LightTouch-v0.0.13-source.tar.gz` |
| --- | --- | --- |
| 角色 | 模拟引擎（QEMU 8.2.0 分支） | App 外壳 / 前端 |
| 内容 | 8 块老 Apple 板子的设备模型、host GL bridge、guest agent | IPSW 制备、UI、Legacy Store、usbmux |
| 许可 | GPL-2.0 | GPL-2.0-or-later |

模拟的是 **2007–2011 年的经典设备**（初代 iPhone、iPod touch 1G–4G、iPhone 3GS/4、初代 iPad），跑 Apple 原厂固件 iPhone OS 1 – iOS 7。guest 是 32 位 ARM，host 是 arm64，用 QEMU TCG 动态翻译，**无硬件虚拟化**。

关键发现：v0.0.13 源码包**已自带 iOS 宿主嵌入层** —— `contrib/ios-app/qemu-ios-ui.h`（52 个 `qemu_ios_*` ABI）、`qemu-ios-entry.c`（App 在后台 pthread 调 `qemu_ios_main`）、`hw/arm/gles-host-eagl.c`（EAGLContext + IOSurface），连 `configure` 都为 iPhone cross build 补了 `needs_exe_wrapper` 与 `objc_link_args`。缺的只是 iOS 交叉编译链和 App 链接，本项目补的就是这两块。详见 [`docs/PORTING.md`](docs/PORTING.md)。

## 多个 workflow

| 文件 | 触发 | 职责 |
| --- | --- | --- |
| `build-unsigned-ipa.yml` | `push` / 手动 / 被调用 | **每次提交自动打包** IPA 并发布 Releases |
| `engine-source.yml` | 手动 / 被调用 | ① 源码 SHA256 校验 + iOS 能力清单 |
| `engine-sysroot.yml` | 手动 / 被调用 | ② iOS arm64 静态依赖交叉编译 |
| `engine-build.yml` | 手动 / 被调用 | ③ QEMU `configure` → `libqemu-arm.a` |
| `engine-pipeline.yml` | 手动 | 一键 ①→②→③→④ |

全部显式 `runs-on: macos-15`。`push` 只跑约 1 分钟的打包，不触发耗时的 QEMU 编译；引擎成功后产物发到 `engine-latest` Release，之后每次自动打包都会尝试下载并条件链接。完整说明见 [`docs/CI.md`](docs/CI.md)。

**手动跑引擎流水线**：Actions → `引擎 ⋯ 全链编排` → Run workflow。默认 `configure_only=true`（几分钟给诊断结果）；关掉才执行完整 `ninja` 编译与静态库归档。

## 侧载

Releases 里的 `iOiEmulator_unsigned_arm64_*.ipa`：

- **TrollStore**：iOS 14.0–16.6.1 / 17.0 可直接导入（`ldid -S` 已伪签名）
- **AltStore / SideStore / Sideloadly**：用自己的证书重签后安装（免费证书 7 天）
- **JIT（可选）**：StikDebug 可在 iOS 17.4–26.x 重挂 JIT；不启用则走 TCI 解释器，上游实测约 3.3–5.2× 减速

固件需自行从 Apple IPSW 制备并通过 Files App 导入。

## 本地构建（需 macOS + Xcode）

```bash
brew install meson ninja pkg-config autoconf automake libtool gettext bison jq
just fetch-engine       # 或 bash scripts/fetch-engine.sh
just engine             # 本地串起 ①→②→③，产出 engine/prebuilt/libqemu-arm.a
just ipa                # Tuist 会自动条件链接引擎并打包
```

`scripts/build-engine-ios.sh` 是等价的一键入口。CI 与本地共用 `scripts/` 下同一批脚本。

## 边界

- **不可上架 App Store**：2.5.2（下载/执行改变功能的代码）、4.7（模拟 iOS 本身不属复古游戏主机）、Apple 固件版权、GPLv2 与 App Store DRM 冲突（2011 年 VLC 下架）。仅限自用侧载 / 越狱 / 企业签名。
- **GPL-2.0 传染性**：链接 qemu-ios 后整体须开源，见 [`NOTICE.md`](NOTICE.md)。
- **真机验证未做**：JIT 权限、固件制备、helper 单进程化、音频/多点触控都还需人工推进，见 [`docs/PORTING.md`](docs/PORTING.md)。

## 目录

```
.github/workflows/   5 个 macOS workflow
iOiEmulator/         SwiftUI 外壳
EngineLinked/        条件编译的 qemu_ios_* 桥接（仅链接引擎时纳入）
engine/SOURCES.json  源码包锁定清单
scripts/             源码/依赖/configure/归档/链接/打包脚本（CI 与本地共用）
docs/CI.md           流水线与排查
docs/PORTING.md      移植状态、已知卡点、六步路线
```
