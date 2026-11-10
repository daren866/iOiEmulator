# Android 4.0 模拟器 for iOS（基于 UTM，裁剪到 arm）

在 iOS 上用 **UTM**（上游 QEMU 移植）做一个「**安卓 4.0 (Ice Cream Sandwich, API 15)**」
模拟器：App 首次启动从官方源下载 ARM 镜像包，再交给 QEMU 启动。
产物为**未签名 IPA**，可用 AltStore / 爱思 / TrollStore 等侧载，兼容 **arm64 与 arm64e**。

---

## ⚠️ 必须先读：为什么「直接用 UTM 启动这套镜像」目前不行

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

### 两条可行的出路（需你拍板，本仓库已为两者铺好底座）
1. **goldfish QEMU → iOS（路线 1，你已选）**：把 iOS 移植做到 AOSP `external/qemu`
   （带 goldfish 机器）上，得到能跑 `kernel-qemu` 的 iOS QEMU。
   ⚠️ **重要修正**：UTM 现成的 `qemu-10.0.12-utm.patch` 是**现代 QEMU 10** 的 HVF/JIT/Metal 移植，
   **里面 0 行 goldfish 代码，无法机械套到 goldfish QEMU**。路线 1 必须**另写一份 iOS 移植**。
   且「能 boot 这颗 4.0 内核」的 goldfish 机器只在 **2012 年 QEMU 1.x 的 `android-4.0.4` 标签**里，
   现代 AOSP qemu 已删 goldfish。故路线 1 又分两个基座变体（1A 原汁原味/极难，1B 易编译/内核兼容未定），
   **详见 [`docs/ROADMAP-goldfish-port.md`](docs/ROADMAP-goldfish-port.md)**，待你二选一。
2. **改投 `virt` 机器 + 自编译内核**：用 UTM 现有上游 QEMU 的 `-machine virt`，但必须换成**为 virt 编译的 Android 内核 + device tree**，而不是这套 goldfish `kernel-qemu`。即放弃直接套用这两包，改为构建/获取一个 virt 版安卓镜像。

本仓库默认按「UTM-SE + 上游 QEMU」搭好工程与下载/构建链路（出路 2 的底座），并把启动参数按 goldfish 写成参考（出路 1 的底座），由你选择继续哪条。

---

## 已实做并验证的部分

| 模块 | 文件 | 状态 |
|------|------|------|
| 首次启动下载脚本（下载+大小校验+解包+manifest） | `scripts/fetch-android-images.sh` | ✅ 已在本机实跑通过（两个包下载/校验/解包/落盘正确） |
| 裁剪 QEMU TARGET_LIST（删 x86/ppc/riscv/m68k，只留 arm） | `scripts/trim-utm.sh`（改 `build_dependencies.sh` 第 1054 行） | ✅ sed 规则已写，待 CI 实跑 |
| 构建编排（UTM-SE 未签名 IPA，arm64+arm64e） | `scripts/build-android-utm.sh` | ✅ 脚本已写，未编译验证 |
| CI：macos-15 构建未签名 IPA + 镜像产物 | `.github/workflows/build.yml` | ✅ 已写，未跑 |
| 参考 goldfish 启动参数 | `android/Android40.qemu-args.txt` | ✅ 参考 |
| iOS 首次启动下载 + 注册 VM 的接入说明 | `patches/ios-firstlaunch-android.md` | ⚠️ 设计/示例，未编译验证 |

> 核心可验证成果是 `fetch-android-images.sh`：它已用真实的两个包验证过下载、大小校验
> （系统镜像 96,240,395 B / Platform 44,533,475 B）、解包、落盘 `kernel-qemu`/`system.img`/
> `ramdisk.img`/`userdata.img`、生成 `manifest.json`。

---

## 目录结构

```
scripts/
  fetch-android-images.sh   # 下载+校验+解包安卓 4.0 镜像（已验证）
  trim-utm.sh              # 克隆 UTM（经代理）+ 裁剪 TARGET_LIST 到 arm
  build-android-utm.sh     # 编排：构建 UTM-SE 未签名 IPA（路线 2 底座）
  fetch-goldfish-qemu.sh   # 路线 1：基座无关克隆 AOSP external/qemu（1A/1B 两套 ref）
.github/workflows/
  build.yml                # macos-15 CI：构建 UTM-SE 未签名 IPA（路线 2 底座）
  build-goldfish-qemu.yml  # macos-15 CI：克隆 goldfish QEMU 基座并试编 iOS 静态库（路线 1，实验性）
android/
  Android40.qemu-args.txt  # 参考启动命令（goldfish 版 QEMU）
patches/
  ios-firstlaunch-android.md # iOS 首次启动下载 + 注册 VM 的接入说明
  ios-port/README.md        # 路线 1：任何 QEMU→iOS 移植都绕不开的清单
docs/
  ROADMAP-goldfish-port.md  # 路线 1 的完整工程化路线图（1A/1B 二选一）
README.md
```

---

## 本地怎么构建（需 macOS + Xcode）

```bash
# 1) 准备 UTM（克隆 + 裁剪）
bash scripts/trim-utm.sh "$HOME/UTM"

# 2) 构建 UTM-SE 依赖与未签名 IPA（ios-tci = TCG 解释执行，无 JIT，可无签名侧载）
cd "$HOME/UTM"
./scripts/build_dependencies.sh -p ios-tci -a arm64
./scripts/build_utm.sh -k iphoneos -s iOS-SE -a "arm64 arm64e" -o UTM
./scripts/package.sh ipa-se UTM.xcarchive .
# 产出：UTM SE.ipa
```

## 首次启动行为（设计）

App 首次启动调用 `fetch-android-images.sh`（已打进 Bundle）下载并解包镜像到
`Documents/Android40/`，随后注册一台 ARM 安卓虚拟机。详见
`patches/ios-firstlaunch-android.md`。（要在真机 boot 仍需先解决上面的 goldfish 兼容问题。）

## 镜像来源（官方，已验证可达）

- ARM 系统镜像（核心）：`https://dl.google.com/android/repository/sys-img/android/sysimg_armv7a-15_r03.zip`
- Platform 包（启动用不到，按需求下载）：`https://dl.google.com/android/repository/android-15_r05.zip`

## 许可

UTM 及其 QEMU 移植遵循各自的上游许可证（主要为 GPLv2）。本项目为在其之上做裁剪与适配的封装。
