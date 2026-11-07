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
| iOS arm64 静态依赖交叉编译 | ✅ **CI 实测 7/7 全编成**（libffi 3.5.0 / pcre2 / glib 2.83.0 / pixman / proxy-libintl / libgpg-error 1.53 / libgcrypt 1.11.2），约 13 个静态库 | `scripts/build-ios-deps.sh` |
| QEMU `configure` | ✅ **CI 实测退出码 0**，`build.ninja` 191 个 targets，`config-meson.cross` 带 `needs_exe_wrapper = true` | `scripts/configure-engine-ios.sh` |
| QEMU `ninja` 编译 / `libqemu-arm.a` 归档 | ✅ **CI 实测已产出** `libqemu-arm.a`（约 1500+ 成员），并发布到 `engine-latest` Release；归档脚本把 QEMU objects + 入口 objects + sysroot `.a` 用 `libtool -static` 合并 | `scripts/build-engine-lib.sh`、`configure-engine-ios.sh` |
| App 侧链接引擎 → 产出 `engine_linked: true` 的 IPA | 🟡 ③ 已产出引擎库；④ IPA 链接时因静态库单遍扫描缺失 QEMU 内部符号，已改用 `-force_load` 整体拉入，待验证 | `Project.swift`、`build-unsigned-ipa.yml` |
| Swift ↔ `qemu_ios_*` 桥接 + 真实帧显示 | ✅ 代码完成，**未经真机验证** | `EngineLinked/` |
| helper 单进程化、音频、多点触控 | ❌ 未做 | 见下文 |
| 真机启动 iOS guest | ❌ 未验证 | 需 macOS + 真机 + 自备固件 |

## 已解决的卡点（CI 实测）

1. **依赖 sysroot**：libffi 3.4.6 的裸 `.cfi_*` 汇编在 Apple 汇编器上报 invalid CFI → 升 3.5.0；glib 2.80 缺 iOS 处理 → 升 UTM 验证过的 2.83.0，并按 UTM `generate_meson_cross()` 修好 cross file（`host_machine.system = 'ios'`、host 侧 `glib-mkenums` / `glib-compile-resources`、`needs_exe_wrapper = true`、预置 `has_function_pipe2/dup3 = false`）；proxy-libintl 0.4 无 `tests` meson 选项。openssl 对 iOS 非硬依赖（`ipod_touch_pke.c` 的 `<openssl/bn.h>` 被 `#ifndef QEMU_IOS_PORTABLE_CRYPTO` 包住，`hw/arm/meson.build` 的 `dependency('libcrypto')` 只在 `host_os == 'windows'` 分支），已从默认集合移除。
2. **QEMU configure 的两类 native 编译器报错**：cross 模式下 `target/meson.build` 无条件 `subdir()` 19 个架构，hexagon / s390x 的 `native:true` 生成器报 `No build machine compiler` → 临时源码树裁剪为仅 `subdir('arm')`；`meson.build:4837` 构建摘要的 `meson.get_compiler('c', native: true)` 在该 fork 生成的 native file 组合下报 `not specified for build machine` → 改用 host 编译器（纯摘要，不影响实际编译）。另修 `--enable-ucontext` 无效 → `-Dcoroutine_backend=sigaltstack`。**configure 现退出码 0。**
3. **`host_os` 必须保持 `darwin`**：曾考虑把 cross file 的 `host_machine.system` 改成 `ios` 以区分 build machine，但 `hw/arm/meson.build` 的 `appleframeworks` 依赖（CoreFoundation / CoreMedia / CoreVideo / VideoToolbox）和 `meson.build` 的 `supported_oses` 检查都要求 `darwin`，故不能改，只能绕开摘要行。

## 尚未解决的问题（真实卡点）

1. **libgcrypt 依赖（已解决）**：`-DQEMU_IOS_PORTABLE_CRYPTO` 下 `include/hw/arm/portable-crypto.h` 无条件 `#include <gcrypt.h>`，并用 `gcry_mpi_*` 实现 S5L8920 PKE 的 Montgomery 模运算。已按 `contrib/portable/crypto-dependencies.json` 把 libgpg-error 1.53 + libgcrypt 1.11.2 加入 sysroot。两个 autotools 包踩了三个坑，均已在 `build-ios-deps.sh` 修掉：
   - 全局 `LDFLAGS`（含 iPhoneOS sysroot）污染 host 工具链接，`/usr/bin/cc` 编出的 `mkheader` / `gost-s-box` 在 macOS 上 `Killed: 9` → 给这两个包隔离干净的 `CFLAGS_FOR_BUILD` / `LDFLAGS_FOR_BUILD` / `CC_FOR_BUILD`；
   - workflow 级 `IPHONEOS_DEPLOYMENT_TARGET=15.0` 被 clang driver 自动读取，导致 host 工具也被标成 iOS 平台 → 在 configure/build/install 三个阶段 `unset` 该变量及 `SDKROOT` / `MACOSX_DEPLOYMENT_TARGET` 之外的 Xcode 注入；
   - iOS SDK 把 `getentropy` 声明藏在可用性宏下，`AC_CHECK_FUNCS` 判存在却无声明 → 给 libgcrypt 传 `ac_cv_func_getentropy=no`，走 `linux` RNG 模块（PKE 只用 MPI，不依赖 CSPRNG）。
   - 现 **7/7 依赖全编成**。注意 QEMU 的 gcrypt feature 仍保持 `--disable-gcrypt`，这里只提供头文件与静态库供便携引擎直接调用。
1b. **iOS EAGL 渲染后端（已绕过）**：`hw/arm/gles-host.c` 的 `TARGET_OS_IPHONE` 分支只 include ES1 头，却用了 desktop GL 常量、`glClipPlane` 等 GLES 不存在的固定管线函数、以及 ES2/ES3 API，且 `gles-host-queue.c.inc` 引用未定义的 `gles_contexts`。上游 `contrib/portable/build-engine.py` 只构建 linux / Android，这条 iOS 路径从未被 CI 编译过，`hw/arm/gles-host.stub.c` 注释也确认「The stub exports every gles_host_* symbol; guest GLES HLE probe fails cleanly」。现 `configure-engine-ios.sh` 对 CI 临时源码树的 `hw/arm/meson.build` 把 backend 选择块替换为只编官方 `gles-host-stub.c`：guest 的 GLES HLE 会干净失败并回退软件渲染。**代价：iOS 端 GPU 加速渲染（EAGL）暂不可用，画面走纯软渲染**，留作后续单独修复。
1c. **最终链接缺 libgcrypt（已修）**：QEMU 因 `--disable-gcrypt` 不会把 libgcrypt 链进 `qemu-system-arm-unsigned`，但 `hw/arm/ipod_touch_pke.c` 经 `portable-crypto.h` 直接调用 `gcry_mpi_*` 实现 S5L8920 的 Montgomery PKE，导致链接报 `"Undefined symbols: gcry_mpi_*"`。已在 `configure-engine-ios.sh` 的 `LDFLAGS_IOS` 末尾补 `-lgcrypt -lgpg-error`（顺序符合依赖关系）。
1d. **归档阶段嵌入层编译缺 target include（已修）**：`build-engine-lib.sh` 原本只复用 `system/main.c` 的编译参数来编译 `qemu-ios-entry.c` / `qemu-ios-ui.c`，但这两个文件经由 arm target 头文件间接 `#include "cpu-param.h"`，该 quote-include 需要 `-DCOMPILING_PER_TARGET` 与 `-I <src>/target/arm`，而 main.c 命令里没有。改为对整张 `compile_commands.json` 取 `-I/-iquote/-isystem/-F/-D` 的并集作为 `base`，覆盖所有 target 专属路径与宏（注意各标志必须保持原始 token 化，`-arch/-isysroot` 等复合标志由 `ios-clang` 包裹脚本自动提供，无需重复收集）。
1e. **App 链接引擎库缺 QEMU 内部符号（已修）**：`libqemu-arm.a` 是由 `libtool -static` 把「QEMU 全部 objects + 入口 objects + sysroot 依赖 .a」合并的单一归档。④ IPA 链接最初用 `-lqemu-arm`，链接器单遍扫描只会拉入 App 直接引用的成员（如 `qemu-ios-ui.o`），而它依赖的 `qemu_mutex_init` / `qemu_mutex_lock_func` 等 QEMU 内部符号所在成员若排在后面，单遍扫描就解析不到，报 `Undefined symbols`。在 `Project.swift` 改用 `-Wl,-force_load,<engine/prebuilt>/libqemu-arm.a` 强制拉入全部成员，再由 Xcode 的 `-dead_strip` 回收未用符号。
2. **`qemu-macos-extras.c` 的平台假设**：`make-shared.py` 会把 macOS 控件/音频实现改写后用于 Linux/Android，但里面引用了 `ui/cocoa.m` 相关符号。iOS host 需要等价的 UIKit 改写，当前 `build-engine-lib.sh` 只编译 `qemu-ios-entry.c` + `qemu-ios-ui.c`，未包含 extras。
3. **helper 单进程化**：App 壳层依赖 usbmuxd daemon、FirmwareKit、GuestAgent 等独立进程；iOS 禁止 `fork/exec`，必须改成进程内线程 + 静态库调用。
4. **音频与多点触控**：上游研究注明音频输出有未修 bug、麦克风完全没写，多点触控尚未实现。
5. **固件制备**：IPSW 解密、NAND 镜像制备不能放进 CI / 仓库，需使用者在受控环境完成，通过 Files App 导入。引擎可用 `migrate file:` 快照跳过约 2 分 50 秒的开机。
6. **JIT**：普通 iOS App 拿不到可写可执行内存。当前流水线固定用 `--enable-tcg-interpreter`（TCI），上游实测约 3.3–5.2× 减速；侧载后可用 StikDebug 重挂 JIT，但不是 CI 能覆盖的。

## 六步路线（更新版）

1. **依赖 sysroot**：`scripts/build-ios-deps.sh` 交叉编译 libffi / proxy-libintl / pcre2 / glib / pixman / libgpg-error / libgcrypt 为 iOS arm64 静态库（openssl 可选、默认不编） → `engine-sysroot.yml`
2. **QEMU configure**：`--cross-prefix=` 强制 cross 模式，`-Dtcg_interpreter=true`，`--with-devices-arm=portable`，`--disable-*` 去掉 iOS 不支持的 host 特性 → `scripts/configure-engine-ios.sh`
3. **引擎归档**：ninja 编译 `qemu-system-arm`，替换 `system/main.c.o` 为 iOS 入口，把 QEMU objects + sysroot `.a` 用 `libtool -static` 合成单个 `libqemu-arm.a` → `scripts/build-engine-lib.sh`
4. **App 链接**：`scripts/prepare-engine-link.sh` 放置产物，`Project.swift` 条件加入 `EngineLinked/` 源码、`OTHER_LDFLAGS` 与系统 framework → `build-unsigned-ipa.yml`
5. **UI 接入**：`QemuEngineBridge` 包装 `qemu_ios_main` / `qemu_ios_ui_frame` / `qemu_ios_ui_touch`；`QemuEngineHostView` 用 `CADisplayLink` 把 BGRA 转 CGImage（已完成，待真机验证）
6. **真机验证**：自备 NAND/NOR + 快照，侧载 IPA，验证首帧、触摸、暂停/恢复；再按需补 helper 单进程化、音频、多点触控

## 边界

- **许可**：qemu-ios 是 GPL-2.0，链接后整体须开源；GPLv2 与 App Store DRM 存在已知冲突（2011 年 VLC 下架）。
- **审核**：App Store 2.5.2（下载/执行改变功能的代码）、4.7（复古游戏主机模拟器不含「模拟 iOS 本身」）、Apple 固件版权 —— 三条都过不去。仅限自用侧载 / 越狱 / 企业签名。
- **固件**：仓库、CI、IPA 均不含任何 Apple 固件、IPSW 或解密组件。
