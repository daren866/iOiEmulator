# iOS 移植清单（任何 QEMU → iOS 都绕不开）

> 这是「路线 1：goldfish QEMU 跑在 iOS 上」的移植工作清单。由 UTM 的
> `qemu-10.0.12-utm.patch`（4550 行，HVF/JIT + Metal + Spice + apple-gfx）提炼而成——
> 但 UTM 的补丁针对 **QEMU 10（meson + 线程 coroutine + HVF/TCI）**，**无法直接套到
> 2012 年 QEMU 1.x 的 goldfish 基座（1A）**。本清单描述的是「在任何 QEMU 基座上做 iOS 移植」
> 必须解决的共性问题，具体补丁需按所选基座（1A 或 1B）逐条生成。

## 1. 执行模式：固定 TCG，禁用一切 JIT

- 关 `KVM`、`HVF`、`TCG JIT` 代码路径。SE/无签名侧载要求**纯解释执行**。
- 若基座支持 TCI（Tiny Code Generator 解释器），优先 TCI；否则用 TCG 但关掉 JIT 后端。
- UTM 的 `ios-tci` 平台即此思路：`build_dependencies.sh -p ios-tci`。

## 2. 移除 / 回退 Linux-only 能力

- 整个 `linux-user`（用户态模拟）移除——iOS 上无意义且大量依赖 Linux syscall。
- `getauxval` / `personality` / `brk` / `syscall` 等：给 iOS 回退或 `#ifdef CONFIG_IOS` 关闭。
- `vhost`、`vhost-user`、virtio 宿主后端：关闭（iOS 上无宿主 virtio）。

## 3. coroutine 后端

- iOS 对 `ucontext` / `sigaltstack` 支持不稳。确认 coroutine 用 **gthread（线程）后端**。
- 1A（2012 qemu）默认 `sigaltstack`，需切到 `gthread` 或 `ucontext`（若基座支持）。

## 4. 软 MMU 的 SIGSEGV 路径

- TCG 靠捕获 `SIGSEGV` 做软 MMU 缺页。iOS 对信号有额外限制（不能在某些线程上、
  不能改信号栈等）。需沿用 UTM 已验证的 iOS 信号处理方式（见其 patch 中 `accel/tcg`、`util/coroutine` 相关改动）。

## 5. 显示 / 输入后端（1A 最大的一块）

- 移除 `SDL` / `GTK` / `X11` / 依赖 X 的 `cocoa`。
- 换成 iOS 原生 framebuffer + **Metal** 输出（或复用 UTM 的 `apple-gfx.m` / `spice` 路线）。
- 输入：触摸 → 相对/绝对指针事件注入到 goldfish/ranchu 的输入设备。

## 6. 网络

- 保留 `slirp`（用户态 NAT，自带），关 `tap` / 宿主 `virtio-net` / `bridge`。
- 这样安卓里的 `eth0` 能 NAT 出网，adb 走 `redir` 或 `goldfish pipe`。

## 7. 音频

- 最小 `coreaudio` 后端；关 ALSA/PulseAudio/OSS。

## 8. 构建 / 链接为 iOS 静态库

- 静态链接进 App；关 `modules`、`make install`、rpath。
- `--target-list` 只留 `arm-softmmu`（1B 再加 `aarch64-softmmu`），大幅减编译量。
- 用 `iphoneos` SDK、`ARCHS=arm64 arm64e`、最低部署目标按你设备定（iOS 15+ 较稳）。
- 1A（autotools）与 1B（meson）的 configure 参数不同，见各自基座的构建脚本。

## 9. goldfish 专属（仅 1A）

- `hw/goldfish/*`、`hw/android/*` 保持编译：fb、nand、mmc、uart、audio、battery、events、pipe。
- 内核命令行参考见 `android/Android40.qemu-args.txt`（goldfish 启动参数）。

## 10. 验证清单（到 Mac / macos-15 上做）

- [ ] 基座克隆成功（goldfish 机器在树内，1A）
- [ ] configure 出 iOS 静态库（TCG-only，target=arm-softmmu）
- [ ] 链接进 App 不报未定义符号
- [ ] 启动：能加载 `kernel-qemu` 并走到 `Uncompressing Linux...` 之后
- [ ] goldfish fb 出画面、触屏可用、网络 NAT 通、adb 连上
