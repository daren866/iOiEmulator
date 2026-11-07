// swift-tools-version: 6.0
import PackageDescription

#if TUIST
    import struct ProjectDescription.PackageSettings

    let packageSettings = PackageSettings(
        productTypes: [:]
    )
#endif

let package = Package(
    name: "iOiEmulator",
    dependencies: [
        // 引擎移植完成后，在此接入 libqemu-arm 的 XCFramework / 二进制依赖。
        // 目前保持空依赖，保证 CI 能稳定产出未签名 IPA。
    ]
)
