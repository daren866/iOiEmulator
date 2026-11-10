# 路线图：把 Android 4.0 模拟器真正跑在 iOS 上（路线 1 / goldfish QEMU）

> 本文件是 `README.md` 里「出路 1」的工程化展开。结论先行：**不能把 UTM 现成的 iOS 补丁直接套到 goldfish QEMU 上**，路线 1 必须在某个「带 goldfish 机器」的 QEMU 基座上**另写一份 iOS 移植**。

---

## 0. 已核实的事实（决定一切）

1. **你给的 `kernel-qemu` 是 AOSP goldfish 内核**（文件名即标志），`build.prop` 显示
   `ro.build.version.sdk=15` / `release=4.0.4` / `cpu.abi=armeabi-v7a` / `device=generic`。
   它只能跑在 goldfish 虚拟板上（nand/mmc/uart/fb/audio/battery/events 等外设地址编译期绑死）。
2. **UTM 的上游 QEMU 没有 goldfish 机器**（只有 `virt`/`raspi`），所以 UTM 直接启动这套镜像会失败——这不是配置问题。
3. **UTM 的 iOS 移植补丁 `qemu-10.0.12-utm.patch`（4550 行）几乎全是**：
   `hvf`（macOS 硬件虚拟化/JIT，311 处）+ `virtio-gpu`/`Metal`/`apple-gfx`（图形）+ `spice`（远程显示）
   对**现代 QEMU 10** 的改动。**里面 0 行 goldfish / Android 代码**。
   → 该补丁针对的是 QEMU 10 的 meson 构建、线程化 coroutine、HVF/TCI 结构；
   **与 2012 年 QEMU 1.x 的 autotools 结构、信号级 coroutine 完全不同，无法机械移植**。
4. 能 boot 你这颗 4.0 内核的 goldfish 机器，只活在 **AOSP `platform/external/qemu`**
   的 **`android-4.0.4` 时代标签**（QEMU 1.x 级别）。现代 AOSP qemu 已把 goldfish 换成
   ranchu/cuttlefish，且 modern clang 工具链对它更友好，但 goldfish 机器本身已被删除。

## 1. 结论：路线 1 必须「另写一份 iOS 移植」，且有两个基座可选

| 变体 | 基座 QEMU | 能否 boot 这套 4.0 镜像 | 在 iOS 上编译的可行性 | 工作量 |
|------|-----------|--------------------------|------------------------|--------|
| **1A（原汁原味）** | AOSP `external/qemu` @ `android-4.0.4_r2.1`（真·goldfish QEMU 1.x） | ✅ 设计上完全匹配（同一代产物） | ⚠️ 低：2012 代码、autotools、Linux 中心假设、信号级 coroutine，需大量手工适配 clang/arm64/iOS | 极大 |
| **1B（更易编译）** | 现代 AOSP `external/qemu`（ranchu + Android 设备，clang 可编） | ❓ 不确定：goldfish 机器已被删，ranchu 启动 2012 goldfish 内核未经验证，大概率需换 ranchu/更新的内核 → 偏离「原样镜像」 | ✅ 较高：工具链现代、接近 UTM 的移植手法 | 大 |

> 简单说：
> - **1A = 一定 boot 得起来（同一代），但 iOS 移植极难**；
> - **1B = iOS 上更容易编出二进制，但那颗 4.0 内核能否在 ranchu 上起来是未知数**，可能要换内核。

两条路都**无法在本 Linux 沙箱完成/验证**（无 iOS SDK、无 Mac），都必须到 `macos-15` runner 或本地 Mac 上实编。

## 2. 任何 QEMU → iOS 移植都绕不开的清单（已据 UTM patch 提炼）

见 `patches/ios-port/README.md`。要点：

- **执行模式固定为 TCG（解释执行）**：禁用 KVM / HVF / 任何 JIT；SE 模式再用 TCI 进一步去掉 JIT 依赖，才能无签名侧载。
- **禁用 Linux-only 特性**：`linux-user` 整个移除；`getauxval`/`personality`/`brk`/vhost 等给 iOS 回退或关闭。
- **coroutine 后端**：确保用线程/gthread 后端（iOS 对 ucontext/sigaltstack 支持不稳）；2012 qemu 默认 sigaltstack，1A 需改。
- **MMU 缺页走 SIGSEGV 的路径**：TCG 在 iOS 上要靠 SIGSEGV 做软 MMU，需确认信号在 iOS 的限制下可用（UTM 已解决）。
- **显示/输入后端替换**：去掉 SDL/GTK/X11/cocoa-with-x11，换成 iOS 的 framebuffer + Metal（或复用 UTM 的 `apple-gfx` / `spice` 路线）。**这是 1A 最大的一块**。
- **网络**：保留 `slirp`（用户态 NAT），关掉 tap/virtio-net 宿主后端。
- **音频**：最小 coreaudio 后端。
- **静态链接进 App**、关掉 modules / 安装步骤、`--target-list` 只留 `arm-softmmu`（1B 再加 `aarch64-softmmu`）。

## 3. 本仓库已铺好的通用底座

- `scripts/fetch-goldfish-qemu.sh`：基座无关地克隆 AOSP `external/qemu`（支持 1A/1B 两套 ref），
  经代理拉取、可选套用 `patches/ios-port/` 下的补丁。供 CI（mac runner）和本地 Mac 使用。
- `patches/ios-port/`：iOS 移植清单 + 后续要落地的补丁目录（目前是清单，补丁待按所选基座生成）。
- `.github/workflows/build-goldfish-qemu.yml`：macos-15 上尝试「克隆基座 → 配置 TCG-only → 编译 iOS 库」的 CI 骨架（**实验性，未验证**，缺 ios-port 补丁时 configure/make 会失败，属预期）。

## 4. 待你拍板

选 **1A** 还是 **1B**？这决定后续所有移植工作的基座与风险剖面（见上表）。
选定后我会：
- 1A：拉 `android-4.0.4` 标签、把上面清单逐条落成对该基座的补丁、`--target-list=arm-softmmu`、goldfish 机器保持编译。
- 1B：拉现代 AOSP qemu 标签、按 UTM 手法做 meson 级 iOS 移植、并实测 ranchu 能否带起 4.0 内核（不能则明确告诉你需换内核）。
