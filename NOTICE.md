# 授权与第三方声明

本仓库的 **App 外壳、Swift 抽象层、CI 工作流与脚本** 采用 MIT 许可（见 `LICENSE`）。

## 引擎代码是 GPL，不是 MIT

`engine/SOURCES.json` 锁定并可由 `scripts/fetch-engine.sh` 拉取的两份源码：

| 项目 | 许可证 |
| --- | --- |
| `blake-lucas/LightTouch` (`v0.0.13`) | **GPL-2.0-or-later** |
| `blake-lucas/qemu-ios` (`lighttouch-v0.0.13`) | **GPL-2.0** |
| 上游 QEMU 8.2.0 | GPL-2.0（部分文件为其他兼容许可） |

一旦把 `libqemu-arm` 链接进 App，**整个组合作品必须按 GPL-2.0 条款提供对应源代码**，
并保留各组件自带的许可证与源码声明（GLib、pixman、libslirp、PCRE2、OpenSSL、
FFmpeg、libimobiledevice、libusbmuxd、libplist、libtatsu、egui 及 Rust crates 等）。
因此：

- 自用 / 侧载：没问题，但不要误以为可以闭源分发。
- 任何形式的公开分发：需随 IPA 提供完整对应源码与构建脚本，或取得全部版权持有人授权。
- App Store 分发：还存在 GPLv2 与 App Store 条款的已知冲突（见 `docs/PORTING.md` 第 4 节），
  且本类应用本身也难过审。

## Apple 固件

本仓库、CI 缓存与产出的 IPA **均不含** Apple 的 IPSW、解密后的系统组件、
NAND 镜像或 SDK。iPhone / iPod touch / iPad 是 Apple Inc. 的商标，
本项目与 Apple 无任何关联。

固件由使用者自行获取并在受控环境制备；请遵守所在地法律与 Apple 的相关条款。

## 参考模板

工程结构与工作流参考自 `daren866/gudaoios-testyes`（Tuist SwiftUI Starter，MIT，
Copyright 2025 Fabian S. Klinke），已按要求改名、重写并增加 Releases 发布能力。
