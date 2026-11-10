# iOS 端「首次启动下载安卓 4.0 镜像并注册虚拟机」接入说明

> ⚠️ 本文件是**接入设计说明 + 示例 Swift 片段**，未经编译/实机验证。
> 把 `scripts/fetch-android-images.sh` 作为资源打进 App Bundle，首次启动时调用它
> 下载并解包镜像，再用 UTM 的配置模型注册一台 ARM 安卓虚拟机。
> 真正能 boot 仍需「goldfish 版 QEMU」（见根 README），因此下面的 VM 配置需配套修改。

## 1. 把下载脚本打进 App

把 `scripts/fetch-android-images.sh` 加入 UTM 的 App 资源（Xcode 里 Add to Target），
或放到 `Platform/UTM/` 资源目录，构建后位于 `Bundle.main.url(forResource: "fetch-android-images", withExtension: "sh")`。

## 2. 首次启动调用下载（示例）

```swift
import Foundation

struct AndroidImageBootstrap {
    static func ensureImages() async throws {
        let fm = FileManager.default
        let out = try fm.url(for: .documentDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("Android40", isDirectory: true)
        guard fm.fileExists(atPath: out.appendingPathComponent("system.img").path) else {
            try await download(outDir: out)
            return
        }
        print("Android40 镜像已存在，跳过下载")
    }

    private static func download(outDir: URL) async throws {
        guard let sh = Bundle.main.url(forResource: "fetch-android-images", withExtension: "sh") else {
            throw NSError(domain: "AndroidBootstrap", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 fetch-android-images.sh"])
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [sh.path, "OUT_DIR=\(outDir.path)"]
        proc.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "AndroidBootstrap", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "镜像下载/解包失败"])
        }
    }
}
```

在 `UTMApp` 启动入口（如 `VMListView` 的 `.task` 或 `AppDelegate`）调用：

```swift
.task {
    try? await AndroidImageBootstrap.ensureImages()
}
```

## 3. 注册一台 ARM 安卓虚拟机（示例）

UTM 的配置模型在 `Configuration/`（如 `UTMConfiguration.swift`、`UTMAppleConfiguration*.swift`、
`UTMQEMUConfiguration*.swift`）。概念上：

```swift
// 伪代码：用解包出的镜像创建 QEMU system arm 配置
let cfg = UTMQEMUConfiguration(system: .arm)   // arm32 客户机
cfg.boot = .kernel(url: outDir.appendingPathComponent("kernel-qemu"))
cfg.drives = [
    .init(url: outDir.appendingPathComponent("system.img"),  interface: .virtio, readOnly: true),
    .init(url: outDir.appendingPathComponent("ramdisk.img"), interface: .virtio),
    .init(url: outDir.appendingPathComponent("userdata.img"), interface: .virtio),
]
cfg.arguments = ["-machine", "goldfish", "-cpu", "cortex-a8", "-m", "256",
                 "-append", "console=ttyS0 androidboot.hardware=goldfish"]
UTMData.shared.save(vm: UTMVirtualMachine(configuration: cfg, packageURL: nil))
```

> 注意：`-machine goldfish` 只在 goldfish 版 QEMU 有效。若用 UTM 的上游 QEMU，
> 这里需改为 `-machine virt` 并配套 virt 设备树 / 内核，否则无法启动（见 README）。
