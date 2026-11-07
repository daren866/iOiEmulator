# CI 流水线

所有 workflow 都**显式运行 `runs-on: macos-15`**（Apple Silicon M1，3 核 / 7 GB / 14 GB SSD，公开仓库免费且不限时长）。`xcodebuild`、`xcrun`、`iphoneos SDK` 只有 macOS runner 提供，iOS 交叉编译无处可替。

## 多个 YAML 的分工

| 文件 | 触发 | 职责 | 主要产物 |
| --- | --- | --- | --- |
| [`build-unsigned-ipa.yml`](../.github/workflows/build-unsigned-ipa.yml) | `push` / `workflow_dispatch` / `workflow_call` | **每次提交自动打包**未签名 arm64 IPA 并发布到 Releases | `unsigned-ipa-N` artifact + `build-N` Release |
| [`engine-source.yml`](../.github/workflows/engine-source.yml) | `workflow_call` / `workflow_dispatch` | ① 拉取两份锁定源码、SHA256 校验、核验 iOS 嵌入层并生成清单 | `engine-source` artifact |
| [`engine-sysroot.yml`](../.github/workflows/engine-sysroot.yml) | `workflow_call` / `workflow_dispatch` | ② 交叉编译 iOS arm64 静态依赖 | `ios-sysroot` artifact |
| [`engine-build.yml`](../.github/workflows/engine-build.yml) | `workflow_call` / `workflow_dispatch` | ③ QEMU `configure` →（可选）`ninja` → `libqemu-arm.a` | `qemu-engine` artifact + `engine-latest` Release |
| [`engine-pipeline.yml`](../.github/workflows/engine-pipeline.yml) | `workflow_dispatch` | 手动一键串起 ①→②→③→④ | 同上全部 |

`engine-pipeline.yml` 用 `workflow_call` 调用前三者，被调用的 jobs 与调用者**属于同一个 run**，因此 `actions/upload-artifact@v4` / `download-artifact@v4` 直接共享产物，不需要传 `run-id`。每一步也都能在 Actions 页面单独手动触发调试。

> 设计取舍：`push` **不会**触发引擎编译（QEMU 全量编译动辄数十分钟）。提交只跑 45–60 秒的 IPA 打包；引擎流水线按需手动跑。引擎成功后产物发到 `engine-latest` Release，之后每次自动打包都会尝试下载它并条件链接。

## 自动打包流程（push）

1. `Checkout` → 显示工具链（`sw_vers` / `uname -m` / `xcodebuild -version` / SDK 版本）
2. **准备引擎链接**（`scripts/prepare-engine-link.sh`）：按「同 run artifact → `engine-latest` Release → 本地 `engine/prebuilt/`」顺序找 `libqemu-arm.a`；找不到不算错误，照常产出外壳 IPA，并把 `ENGINE_LINKED` 写进 `$GITHUB_ENV`
3. `Install Tuist and ldid` — 固定版本 `4.215.0` 直连 GitHub Release 下载官方 `tuist.zip`，用 `SHASUMS256.txt` 校验，失败回退 gh-proxy 镜像；`ldid` 可选，缺失时只产出纯未签名 IPA
4. `tuist generate --no-open` — `Project.swift` 按 `engine/prebuilt/libqemu-arm.a` 是否存在，条件纳入 `EngineLinked/` 桥接源码并追加 `OTHER_LDFLAGS`
5. `xcodebuild clean archive` — `CODE_SIGNING_ALLOWED=NO` / `ARCHS=arm64` / `IPHONEOS_DEPLOYMENT_TARGET=15.0` / `SKIP_INSTALL=NO`
6. `Verify archive binary` — `lipo -archs` 必须是 arm64，`codesign -dv` 预期未签名
7. `Package IPA` — `scripts/package-ipa.sh`，`ldid -S` 做 ad-hoc 伪签名供 TrollStore，生成 `SHA256SUMS` 与 `build-info.txt`
8. 上传 14 天 Artifacts 备份 + 发布 `build-N` prerelease（用自动 `GITHUB_TOKEN`，**不需要 PAT**）

自建 `build-N` tag 用 `tags-ignore: ['**']` 排除，不会造成循环触发（已实测）。

## 引擎流水线（手动）

在 Actions → `引擎 ⋯ 全链编排` → Run workflow：

| Input | 默认 | 说明 |
| --- | --- | --- |
| `configure_only` | `true` | 只跑 `configure`，几分钟给可诊断结果；关掉才执行完整 `ninja` + 静态库归档 |
| `build_ipa` | `true` | 引擎阶段结束后重新打包 IPA |
| `packages` | `libffi,pcre2,glib,pixman,proxy-libintl,libgpg-error,libgcrypt` | 依赖集合（openssl 对 iOS 非必需；libgcrypt 是便携引擎 PKE 的硬依赖，见下） |

每个阶段都会产出报告：

- `sysroot-report.json` — 逐包成功/失败、阶段、耗时、日志路径
- `build-report.md` / `build-report.json` — configure 状态、依赖统计、引擎清单、失败日志末段
- 报告同时写进 Actions Step Summary 和 `engine-latest` Release 说明

依赖逐包独立编译、**失败不中断**，所以即使 glib 等某包没编成，CI 仍会给出精确的失败阶段与日志，而不是整条流水线静默挂掉。

## 移除 UTM 全家桶的原因

UTM 的 `scripts/build_dependencies.sh -p ios-tci -a arm64` 会连带编译 gstreamer / spice-gtk / ANGLE / Vulkan / MoltenVK / WebKit，并要求 `brew install llvm spirv-llvm-translator libxcb libxrandr` 等一整套 host 工具。在标准 macOS runner 的 3 核 / 14 GB 磁盘上几乎必然超时或撑爆磁盘。

本仓库改用 `scripts/build-ios-deps.sh`，只编 `--without-default-features` 真正探测到的库，版本与 SHA256 直接取自 qemu-ios 源码包 `contrib/portable/dependencies.json`。

其中 libgpg-error 1.53 / libgcrypt 1.11.2 取自源码包的 `contrib/portable/crypto-dependencies.json`。它们是**硬依赖**：`-DQEMU_IOS_PORTABLE_CRYPTO` 会让 `include/hw/arm/portable-crypto.h` 直接 `#include <gcrypt.h>` 并用 `gcry_mpi_*` 实现 S5L8920 PKE，`--disable-gcrypt` 只关掉 QEMU 自己的 cipher feature，绕不开这个头文件。libgpg-error 1.53 自带 `lock-obj-pub.aarch64-apple-darwin.h`，正好匹配 `--host=aarch64-apple-darwin`，cross 模式无需上游的 Android lock 补丁。

## 排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `tuist: command not found` | Homebrew 无 `tuist` formula，`install.tuist.io` 在 runner 返回 403；工作流已改为固定版本直连 Release 下载 |
| `glib-2.0.pc` 缺失 / configure 卡在 glib | ② 阶段 glib 未编成；看 `ios-sysroot` artifact 的 `status/glib.log`，iOS cross build 的 `cc.run()` 探测是最常见卡点 |
| `ninja: command not found` / meson 报错 | ③ 的 Homebrew 安装步骤失败，看该步骤日志 |
| `libtool` 归档报重复符号 | `build-engine-lib.sh` 把 sysroot 依赖合并进单个 `.a`，若 ninja 链接命令里已带同名库，检查 `engine-out/ENGINE_MANIFEST.json` 的 `archive_inputs` |
| IPA 里 `engine_linked: false` | 没找到 `libqemu-arm.a`，属预期；先手动跑通引擎流水线并发布 `engine-latest` |
| `ldid` 失败 | 降级为纯未签名 IPA，可用 AltStore / Sideloadly 重签 |
