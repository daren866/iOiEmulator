import ProjectDescription
import Foundation

// iOiEmulator — unsigned iOS arm64 app shell for the qemu-ios / LightTouch engine.
//
// 条件链接：scripts/prepare-engine-link.sh 在 CI 里把 ③ 产出的 libqemu-arm.a
// 放到 engine/prebuilt/ 后，Tuist 才会：
//   1) 把工程根 EngineLinked/ 下的 Swift 桥接源码纳入编译
//   2) 定义 ENGINE_LINKED 编译条件
//   3) 追加静态库搜索路径与系统 framework 链接参数
// 否则只编译外壳，IPA 照常产出。这样 push 自动打包不依赖引擎编译是否成功。

let fileManager = FileManager.default
let projectRoot = fileManager.currentDirectoryPath
let engineDir = "\(projectRoot)/engine/prebuilt"
let engineLinked = fileManager.fileExists(atPath: "\(engineDir)/libqemu-arm.a")

let deploymentTargets: DeploymentTargets = .iOS("15.0")

var appSettings: [String: SettingValue] = [
    "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
    "TARGETED_DEVICE_FAMILY": "1,2",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": engineLinked ? "ENGINE_LINKED" : "SHELL_ONLY"
]

// EngineLinked/ 故意放在工程根（不在 iOiEmulator/ 下），这样默认的
// sources glob 天然不会包含它，无需依赖 Tuist 版本相关的 excluding 语法。
var appSources: [SourceFileGlob] = ["iOiEmulator/**/*.swift"]

if engineLinked {
    appSources.append("EngineLinked/**/*.swift")
    appSettings["LIBRARY_SEARCH_PATHS"] = "$(inherited) \(engineDir)"
    appSettings["HEADER_SEARCH_PATHS"] = "$(inherited) \(engineDir)/include"
    // libqemu-arm.a 已由 build-engine-lib.sh 把 QEMU objects 与 sysroot 依赖
    // 全部合并进单个静态库，因此这里只需 -lqemu-arm + 系统 framework。
    appSettings["OTHER_LDFLAGS"] =
        "$(inherited) -lqemu-arm -lz -liconv" +
        " -framework CoreFoundation -framework CoreGraphics" +
        " -framework CoreMedia -framework CoreVideo -framework VideoToolbox" +
        " -framework OpenGLES -framework IOSurface -framework ImageIO" +
        " -framework Security -framework AudioToolbox -framework Foundation"
}

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
            resources: ["iOiEmulator/Assets.xcassets"]
        )
    ]
)
