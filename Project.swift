import ProjectDescription

// iOiEmulator — unsigned iOS arm64 app shell for the qemu-ios / LightTouch engine.
// Deployment target 15.0 keeps the IPA installable via TrollStore and re-signing sideloaders.
let deploymentTargets: DeploymentTargets = .iOS("15.0")

let project = Project(
    name: "iOiEmulator",
    organizationName: "daren866",
    settings: .settings(
        base: [
            "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO"
        ],
        defaultSettings: .recommended
    ),
    targets: [
        .target(
            name: "iOiEmulator",
            destinations: .iOS,
            product: .app,
            bundleId: "com.daren866.iOiEmulator",
            deploymentTargets: deploymentTargets,
            infoPlist: .file(path: "iOiEmulator/Info.plist"),
            sources: ["iOiEmulator/**/*.swift"],
            resources: ["iOiEmulator/Assets.xcassets"]
        )
    ]
)
