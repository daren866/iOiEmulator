import ProjectDescription
import Foundation

// iOiEmulator — unsigned iOS arm64 app shell for the qemu-ios / LightTouch engine.
//
// 条件链接：scripts/prepare-engine-link.sh 在 CI 里把 ③ 产出的引擎静态库
// 放到 engine/prebuilt/ 后，Tuist 才会：
//   1) 把工程根 EngineLinked/ 下的 Swift 桥接源码纳入编译
//   2) 定义 ENGINE_LINKED 编译条件
//   3) 追加静态库搜索路径与系统 framework 链接参数
// 否则只编译外壳，IPA 照常产出。这样 push 自动打包不依赖引擎编译是否成功。
//
// 引擎链接标志由 prepare-engine-link.sh 生成到 engine_libflags.txt：
//   - libqemu-arm.a 用 -force_load 整体拉入（仅含 QEMU 显式对象 + 入口对象，
//     内部无冲突，可安全 force_load）；
//   - QEMU 工具库与 sysroot 依赖库为独立 .a，放在 -Wl,-start-group ... -Wl,-end-group
//     里惰性链接（只拉被引用的成员，避免与 pci-stub.o 等按需成员冲突）。
// Project.swift 读取该文件，不再硬编码。

let fileManager = FileManager.default
let projectRoot = fileManager.currentDirectoryPath
let engineDir = "\(projectRoot)/engine/prebuilt"
let engineLinked = fileManager.fileExists(atPath: "\(engineDir)/libqemu-arm.a")

let deploymentTargets: DeploymentTargets = .iOS("15.0")

// 读取 prepare-engine-link.sh 生成的引擎链接标志（force_load 核心库 + start-group 其余 .a）。
// 若文件缺失则回退为空串，避免 Tuist 解析失败。
let engineLibFlagsFile = "\(engineDir)/engine_libflags.txt"
let engineLibFlags: String = {
    guard let raw = try? String(contentsOfFile: engineLibFlagsFile, encoding: .utf8) else {
        return ""
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}()

// 写成单个字符串字面量：多段 `+` 拼接会让 Tuist 的 manifest 编译器
// 报 "unable to type-check this expression in reasonable time"。
// 系统 framework 与 -lz/-liconv 始终在引擎链接分支追加；引擎库标志来自文件。
let engineLDFlags: SettingValue = "$(inherited) -L\(engineDir) \(engineLibFlags) -lz -liconv -framework CoreFoundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework OpenGLES -framework IOSurface -framework ImageIO -framework Security -framework AudioToolbox -framework Foundation"

var appSettings: [String: SettingValue] = [
    "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
    "TARGETED_DEVICE_FAMILY": "1,2",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": engineLinked ? "ENGINE_LINKED" : "SHELL_ONLY"
]

if engineLinked {
    appSettings["LIBRARY_SEARCH_PATHS"] = "$(inherited) \(engineDir)"
    appSettings["HEADER_SEARCH_PATHS"] = "$(inherited) \(engineDir)/include"
    // 引擎库标志（含 -force_load 与 start-group 惰性链接）来自 engine_libflags.txt，
    // 再追加系统 framework 与 -lz/-liconv。
    appSettings["OTHER_LDFLAGS"] = engineLDFlags
}

// EngineLinked/ 故意放在工程根（不在 iOiEmulator/ 下），这样默认的
// sources glob 天然不会包含它，无需依赖 Tuist 版本相关的 excluding 语法。
// 类型必须是 SourceFilesList，不能是 [SourceFileGlob]。
let appSources: SourceFilesList = engineLinked
    ? ["iOiEmulator/**/*.swift", "EngineLinked/**/*.swift"]
    : ["iOiEmulator/**/*.swift"]

let project = Project(
    name: "iOiEmulator",
    organizationName: "daren866",
    settings: .settings(base: appSettings, defaultSettings: .recommended),
    targets: [
        .target(
            name: "iOiEmulator",
            destinations: .iOS,
            product: .app,
            bundleId: "com.daren866.iOiEmulator",
            deploymentTargets: deploymentTargets,
            infoPlist: .file(path: "iOiEmulator/Info.plist"),
            sources: appSources,
            resources: ["iOiEmulator/Assets.xcassets", "iOiEmulator/firmware-catalog.json"]
        )
    ]
)
