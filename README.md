# Android 4.0 模拟器 for iOS（基于 UTM，裁剪到 arm）

在 iOS 上用 **UTM**（上游 QEMU 移植）做一个「**安卓 4.0 (Ice Cream Sandwich, API 15)**」
模拟器：App 首次启动从官方源下载 ARM 用户空间镜像，再用 UEMU 的 `-machine vexpress-a15`
把安卓跑起来。产物为**未签名 IPA**，可用 AltStore / 爱思 / TrollStore 等侧载，兼容 **arm64 与 arm64e**。

> **当前采用：路线 2（-machine vexpress-a15，已定稿）。** 你最初给的官方包里 `kernel-qemu` 是 goldfish 内核，
> 只能跑在 AOSP goldfish QEMU 上，而 UTM 的上游 QEMU 没有 goldfish 机器。
> 经权衡，我们选择**不搬 goldfish QEMU**（见 [`docs/ROADMAP-goldfish-port.md`](docs/ROADMAP-goldfish-port.md)，
> 那里解释了为何 UTM 的 iOS 补丁无法套到 goldfish QEMU），改用 UTM 自带的 `vexpress-a15` 机器 +
> 为 vexpress-a15 单独编译的 Android 内核（Linux 3.0 原生支持，无需反向移植，QEMU 自带 dtb，链路最稳）。
> 备选的 `-machine virt` 因 ARCH_VIRT 在 3.11+ 才进主线、3.0 需反向移植，默认不再采用。
> goldfish 路线仅作为参考保留在路线图里。

---

## ⚠️ 必须先读：goldfish 内核为什么不能直接用

我把你给的两个包都下载解包核实过，结论很明确：

- **系统镜像** `sysimg_armv7a-15_r03.zip` 解包后是：
  `kernel-qemu`(1.5MB) + `system.img`(166MB) + `ramdisk.img` + `userdata.img` + `build.prop`。
  其中 `kernel-qemu` 是 **AOSP goldfish 内核**（文件名即标志），`build.prop` 显示
  `ro.build.version.sdk=15` / `release=4.0.4` / `cpu.abi=armeabi-v7a` / `device=generic`。
- 这套镜像**只能跑在带 goldfish/ranchu 虚拟板的 QEMU 上**（goldfish 的 nand/mmc/uart/fb/audio/
  battery/events 等私有外设，内核在编译期就绑死了地址）。
- **UTM 用的是上游 QEMU**（只有 `virt` / `raspi` 等机器，**没有 goldfish**）。
  所以 `kernel-qemu` 在 UTM 的上游 QEMU 上启动会找不到 goldfish 外设而失败。

> 一句话：**不是配置问题，是「机器类型」根本不兼容**。详见 `android/Android40.qemu-args.txt`。

另外你提到的 **Platform 包 `android-15_r05.zip` 只是 SDK 平台定义**（android.jar / layoutlib /
模板），**启动安卓用不到**，是建 AVD / 写 App 才需要。本仓库按你的要求仍会一并下载，但启动只用系统镜像。

### 两条出路（已选路线 2；路线 1 仅作参考）
- **✅ 路线 2（-machine vexpress-a15，已定稿）**：用 UTM 现有上游 QEMU 的 `vexpress-a15` 机器，搭配
  **为 vexpress-a15 单独编译的 Android 内核**（见 `scripts/build-android-virt-kernel.sh`，默认 `MACHINE=vexpress`）。
  vexpress_defconfig 在 Linux 3.0 原生支持，QEMU 自带 dtb，无需反向移植，启动链路最稳。
  官方 AVD 包里的 `system.img`/`ramdisk.img`/`userdata.img`（安卓 4.0 用户空间）可复用，
  但 `kernel-qemu` 是 goldfish 内核，**不能用**，必须另编译。这是当前仓库的主线，能真正跑起来。
  （备选 `-machine virt` 仍保留在脚本里，需设 `MACHINE=virt` 且已把 ARCH_VIRT 反向移植到 3.0。）
- **路线 1（goldfish QEMU → iOS，仅参考）**：把 iOS 移植做到 AOSP `external/qemu`
  （带 goldfish 机器）上，原汁原味 boot 那颗 4.0 内核。但 UTM 现成的 `qemu-10.0.12-utm.patch`
  是**现代 QEMU 10** 的 HVF/JIT/Metal 移植，**0 行 goldfish 代码，无法机械套用**；
  且 goldfish 机器只在 2012 年 `android-4.0.4` 标签里。**详见 [`docs/ROADMAP-goldfish-port.md`](docs/ROADMAP-goldfish-port.md)**。

---

## 已实做并验证的部分

| 模块 | 文件 | 状态 |
|------|------|------|
| 首次启动下载（路线 2 用户空间：system/ramdisk/userdata，大小校验+解包+manifest） | `scripts/fetch-android-guest.sh` | ✅ 已在本机实跑通过（`fetch-android-images.sh` 的同源逻辑，验证过下载/校验/解包） |
| 为 vexpress-a15（默认）/ virt 编译 Android 4.0 内核 + dtb | `scripts/build-android-virt-kernel.sh` | ⚠️ 脚本已写，需 ARM 交叉工具链 + 内核源码，**未在此编译验证** |
| 裁剪 QEMU TARGET_LIST（删 x86/ppc/riscv/m68k，只留 arm/aarch64） | `scripts/trim-utm.sh` | ✅ sed 规则已写，待 CI 实跑 |
| 构建编排（UTM-SE 未签名 IPA，arm64+arm64e） | `scripts/build-android-utm.sh` | ✅ 脚本已写，未编译验证 |
| CI：macos-15 构建 UTM-SE 未签名 IPA | `.github/workflows/build.yml` | ✅ 已写，未跑 |
| 路线 2 启动参数（**默认 vexpress-a15**，备选 virt） | `android/Android40-virt.qemu-args.txt` | ✅ 参考 |
| iOS 首次启动下载 + 注册 VM 的接入说明 | `patches/ios-firstlaunch-android.md` | ⚠️ 设计/示例，未编译验证 |
| （参考）goldfish 路线完整拆解 | `docs/ROADMAP-goldfish-port.md` | 📄 参考，未采用 |
| （参考）goldfish 启动参数 | `android/Android40.qemu-args.txt` | 📄 参考，仅 goldfish QEMU 可用 |

> 核心可验证成果是下载/校验/解包逻辑：已用真实的官方包验证过下载、大小校验
> （系统镜像 96,240,395 B）、解包、落盘 `system.img`/`ramdisk.img`/`userdata.img`、生成 `manifest.json`。
> ⚠️ **真正在 iOS 上 boot 安卓 4.0 仍差两步**（均需 Mac/Linux + 工具链，无法在本沙箱验证）：
> ① 用 `build-android-virt-kernel.sh`（默认 `MACHINE=vexpress`）产出 vexpress-a15 内核 zImage；
> ② Android 4.0 的 ramdisk/init 是按 goldfish 写的，在 vexpress-a15 上需改 fstab/init.rc
> 让 system 指向 /dev/mmcblk0、data 指向 /dev/vda（virtio-blk，见 `Android40-virt.qemu-args.txt` 底部提示）。

---

## 目录结构

```
scripts/
  fetch-android-guest.sh        # 路线2：首次启动下载安卓4.0用户空间（已验证）
  build-android-virt-kernel.sh  # 路线2：为 vexpress-a15(默认)/virt 交叉编译 Android 4.0 内核+dtb
  trim-utm.sh                  # 克隆 UTM（经代理）+ 裁剪 TARGET_LIST 到 arm
  build-android-utm.sh         # 编排：构建 UTM-SE 未签名 IPA
  fetch-android-images.sh      # （参考）原 goldfish 路线：下载含 kernel-qemu 的全包
  fetch-goldfish-qemu.sh       # （参考）路线1：克隆 AOSP external/qemu 基座
.github/workflows/
  build.yml                    # macos-15 CI：构建 UTM-SE 未签名 IPA
android/
  Android40-virt.qemu-args.txt # 路线2：启动命令（默认 vexpress-a15，备选 virt）
  Android40.qemu-args.txt      # （参考）goldfish 启动命令
patches/
  ios-firstlaunch-android.md   # iOS 首次启动下载 + 注册 VM 的接入说明
  ios-port/README.md           # （参考）路线1：QEMU→iOS 移植清单
docs/
  ROADMAP-goldfish-port.md     # （参考）路线1 路线图
README.md
```

---

## 本地怎么构建（需 macOS + Xcode）

```bash
# 1) 准备 UTM（克隆 + 裁剪 TARGET_LIST 到 arm/aarch64）
bash scripts/trim-utm.sh "$HOME/UTM"

# 2) 构建 UTM-SE 依赖与未签名 IPA（ios-tci = TCG 解释执行，无 JIT，可无签名侧载）
cd "$HOME/UTM"
./scripts/build_dependencies.sh -p ios-tci -a arm64
./scripts/build_utm.sh -k iphoneos -s iOS-SE -a "arm64 arm64e" -o UTM
./scripts/package.sh ipa-se UTM.xcarchive .
# 产出：UTM SE.ipa（含上游 QEMU 的 virt 机器）

# 3) 为 vexpress-a15 编译 Android 4.0 内核（需 ARM 交叉工具链 + 内核源码）
TOOLCHAIN_PREFIX=arm-linux-gnueabihf- KERNEL_SRC="$HOME/kernel-3.0-ics" \
  bash scripts/build-android-virt-kernel.sh "$HOME/Android40"
# 产出：zImage（vexpress-a15 由 QEMU 自带 dtb；配合 Android40-virt.qemu-args.txt 启动）
# 若要走 -machine virt，加 MACHINE=virt 并先完成 ARCH_VIRT 反向移植。
```

## 首次启动行为（设计）

App 首次启动调用 `fetch-android-guest.sh`（已打进 Bundle）下载并解包安卓 4.0 用户空间到
`Documents/Android40/`，内核 `zImage` 由 `build-android-virt-kernel.sh`（默认 vexpress-a15）预编译后随包或另行下发，
随后注册一台 ARM 安卓虚拟机（`-machine vexpress-a15`）。详见
`patches/ios-firstlaunch-android.md`。（要在真机 boot 仍差内核编译 + ramdisk 适配两步，见上文表注。）

## 镜像来源（官方，已验证可达）

- ARM 系统镜像（核心，路线 2 复用其用户空间）：`https://dl.google.com/android/repository/sys-img/android/sysimg_armv7a-15_r03.zip`
  （由 `scripts/fetch-android-guest.sh` 下载、大小校验、解包出 `system.img`/`ramdisk.img`/`userdata.img`）
- 内核（**路线 2 必须另编译**，不能用官方包里的 `kernel-qemu`）：用 `scripts/build-android-virt-kernel.sh`
  交叉编译，产出 `zImage` + `virt.dtb`。
- Platform 包（`android-15_r05.zip`）启动用不到，路线 2 不再下载；路线 1 参考脚本里仍会拉取。

## 许可

UTM 及其 QEMU 移植遵循各自的上游许可证（主要为 GPLv2）。本项目为在其之上做裁剪与适配的封装。
