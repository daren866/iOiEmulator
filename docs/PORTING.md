# 移植状态与路线

> 本文记录把 `qemu-ios` / `LightTouch` 引擎真正跑进 iOS arm64 App 的进度。**请勿把「流水线搭好」等同于「模拟器能跑」。**

## 已确认的关键事实（v0.0.13 源码包实测）

上一轮评估认为 iOS 宿主代码需要从头写。实际打开源码包后发现，作者已经把大部分嵌入层写进去了：

| 证据 | 位置 | 含义 |
| --- | --- | --- |
| iOS App ABI 头文件 | `contrib/ios-app/qemu-ios-ui.h` | 52 个 `qemu_ios_*` 符号：`qemu_ios_main`、`qemu_ios_ui_frame`（紧密打包 BGRA）、`qemu_ios_ui_touch`、`qemu_ios_device_info`、快照、输入序列… |
| iOS 入口 | `contrib/ios-app/qemu-ios-entry.c` | 注释明确「Entry point for embedding this emulator in an iOS app」；App 在后台 pthread 调 `qemu_ios_main()`，主线程留给 UIKit |
| EAGL 后端 | `hw/arm/gles-host-eagl.c` | 「the iOS half of the host context」，用 `EAGLContext` + `IOSurface` 离屏 FBO，核对过 iPhoneOS 26.5 SDK 的 457 个 GLES 入口 |
| 平台分支 | `hw/arm/meson.build` | 按 `TARGET_OS_IPHONE` 在 CGL / EAGL 间选择，`appleframeworks` 依赖 CoreFoundation / CoreMedia / CoreVideo / VideoToolbox |
| configure 已改造 | `configure` 第 1860 行附近 | 注释直接点名 iPhone：自动探测「生成的二进制在本机不可运行」并写 `needs_exe_wrapper = true`；补 `objc_link_args` 防止 cross build 丢掉 sysroot `-L` |
| 最小构建配方 | `contrib/portable/build-engine.py` | `--without-default-features --without-default-devices --with-devices-arm=portable` + `portable.mak` |
| 引擎库归档思路 | `contrib/macos-app/make-dylib-macos.sh`、`contrib/portable/make-shared.py` | 从 ninja 链接命令取全部 objects，把 `system/main.c.o` 换成 `qemu-ios-entry.o` + `qemu-ios-ui.o` |

也就是说，**缺的不是 iOS 设备模型或 UI 桥接，而是「iOS 交叉编译链」+「App 侧链接」**，这两部分现在由本仓库的多个 macOS workflow 与脚本承担。

研究文档 `docs/research/ipod-touch-2g-on-iphone.md`（上游，2026-08-03）写于源码包之前，结论 "Verdict: viable / nothing was built from it" 与建议 rebase 到 `utmapp/qemu 10.0.2` 需按上述新证据重新理解：TCI 解释器和 EAGL 路径在本 fork 已可用，rebase 不再是首要阻塞项。

## 当前进度

| 步骤 | 状态 | 落地位置 |
| --- | --- | --- |
| 源码锁定 + SHA256 校验 | ✅ 完成 | `engine/SOURCES.json`、`scripts/fetch-engine.sh` |
| iOS 嵌入层核验与清单 | ✅ 完成 | `scripts/engine-source-manifest.sh` |
| 多个 macOS workflow 串联 | ✅ 完成 | `.github/workflows/*.yml`（5 个，全部 `macos-15`） |
| 未签名 arm64 IPA 自动打包 → Releases | ✅ 已用真实 CI 跑通 | `build-unsigned-ipa.yml` |
| iOS arm64 静态依赖交叉编译 | 🟡 **CI 实测 3/6 成功**（libffi 3.5.0 / pcre2 / pixman）；glib、proxy-libintl、openssl 待修 | `scripts/build-ios-deps.sh` |
| QEMU `configure` / `ninja` / `libqemu-arm.a` 归档 | 🟡 CI 已真实跑到 meson setup；首个硬错误 `-Dcoroutine_backend=ucontext`（iOS 只提供 sigaltstack）已修 | `scripts/configure-engine-ios.sh`、`build-engine-lib.sh` |
| Swift ↔ `qemu_ios_*` 桥接 + 真实帧显示 | ✅ 代码完成，**未经真机验证** | `EngineLinked/` |
| helper 单进程化、音频、多点触控 | ❌ 未做 | 见下文 |
| 真机启动 iOS guest | ❌ 未验证 | 需 macOS + 真机 + 自备固件 |

## 尚未解决的问题（真实卡点）

1. **glib 的 iOS cross build**：meson 在 cross 模式下执行 `cc.run()` 特性探测会失败，且需要 build-machine 侧的 `glib-mkenums` / `glib-compile-resources`。已按 UTM 的 `generate_meson_cross()` 修好 cross file：`host_machine.system = 'ios'`、显式提供 host 工具、`needs_exe_wrapper = true`、预置 `has_function_pipe2/dup3 = false`，并在 CI 装 `glib-utils`。仍需一轮 CI 验证 glib 2.80 是否还触发 `cc.run()` 检查。
1b. **openssl 对 iOS 非必需**：`ipod_touch_pke.c` 的 `<openssl/bn.h>` 被 `#ifndef QEMU_IOS_PORTABLE_CRYPTO` 包住，`hw/arm/meson.build` 的 `dependency('libcrypto')` 只在 `host_os == 'windows'` 分支；configure 已加 `-DQEMU_IOS_PORTABLE_CRYPTO` 走 QEMU 内置 crypto。故默认依赖集不再包含 openssl，需要时可手动加回。
1c. **CI 实测已解决的三个坑**：libffi 3.4.6 的裸 `.cfi_*` 汇编 → 升 3.5.0；glib 2.80 缺 iOS 处理 → 升 UTM 验证过的 2.83.0；`target/meson.build` 无条件 `subdir('hexagon')` 的 `gen_semantics(native:true)` 在 cross 模式下缺 build-machine 编译器 → 只编 arm-softmmu 时注释掉该行（补丁只作用于 CI 临时源码树）。`--enable-ucontext` 也不是本 fork 的有效选项，iOS 只提供 `sigaltstack` coroutine backend。
2. **`qemu-macos-extras.c` 的平台假设**：`make-shared.py` 会把 macOS 控件/音频实现改写后用于 Linux/Android，但里面引用了 `ui/cocoa.m` 相关符号。iOS host 需要等价的 UIKit 改写，当前 `build-engine-lib.sh` 只编译 `qemu-ios-entry.c` + `qemu-ios-ui.c`，未包含 extras。
3. **helper 单进程化**：App 壳层依赖 usbmuxd daemon、FirmwareKit、GuestAgent 等独立进程；iOS 禁止 `fork/exec`，必须改成进程内线程 + 静态库调用。
4. **音频与多点触控**：上游研究注明音频输出有未修 bug、麦克风完全没写，多点触控尚未实现。
5. **固件制备**：IPSW 解密、NAND 镜像制备不能放进 CI / 仓库，需使用者在受控环境完成，通过 Files App 导入。引擎可用 `migrate file:` 快照跳过约 2 分 50 秒的开机。
6. **JIT**：普通 iOS App 拿不到可写可执行内存。当前流水线固定用 `--enable-tcg-interpreter`（TCI），上游实测约 3.3–5.2× 减速；侧载后可用 StikDebug 重挂 JIT，但不是 CI 能覆盖的。

## 六步路线（更新版）

1. **依赖 sysroot**：`scripts/build-ios-deps.sh` 交叉编译 libffi / proxy-libintl / pcre2 / glib / pixman / openssl 为 iOS arm64 静态库 → `engine-sysroot.yml`
2. **QEMU configure**：`--cross-prefix=` 强制 cross 模式，`-Dtcg_interpreter=true`，`--with-devices-arm=portable`，`--disable-*` 去掉 iOS 不支持的 host 特性 → `scripts/configure-engine-ios.sh`
3. **引擎归档**：ninja 编译 `qemu-system-arm`，替换 `system/main.c.o` 为 iOS 入口，把 QEMU objects + sysroot `.a` 用 `libtool -static` 合成单个 `libqemu-arm.a` → `scripts/build-engine-lib.sh`
4. **App 链接**：`scripts/prepare-engine-link.sh` 放置产物，`Project.swift` 条件加入 `EngineLinked/` 源码、`OTHER_LDFLAGS` 与系统 framework → `build-unsigned-ipa.yml`
5. **UI 接入**：`QemuEngineBridge` 包装 `qemu_ios_main` / `qemu_ios_ui_frame` / `qemu_ios_ui_touch`；`QemuEngineHostView` 用 `CADisplayLink` 把 BGRA 转 CGImage（已完成，待真机验证）
6. **真机验证**：自备 NAND/NOR + 快照，侧载 IPA，验证首帧、触摸、暂停/恢复；再按需补 helper 单进程化、音频、多点触控

## 边界

- **许可**：qemu-ios 是 GPL-2.0，链接后整体须开源；GPLv2 与 App Store DRM 存在已知冲突（2011 年 VLC 下架）。
- **审核**：App Store 2.5.2（下载/执行改变功能的代码）、4.7（复古游戏主机模拟器不含「模拟 iOS 本身」）、Apple 固件版权 —— 三条都过不去。仅限自用侧载 / 越狱 / 企业签名。
- **固件**：仓库、CI、IPA 均不含任何 Apple 固件、IPSW 或解密组件。
