import SwiftUI

struct ContentView: View {
    @State private var selection: Int = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationView { StatusView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("状态", systemImage: "gearshape") }
                .tag(0)

            NavigationView { BoardListView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("设备", systemImage: "list.bullet") }
                .tag(1)

            NavigationView { GuideView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("侧载", systemImage: "questionmark.circle") }
                .tag(2)
        }
    }
}

private struct StatusView: View {
    private let engine: EmulatorEngine = UnavailableEngine()

    var body: some View {
        List {
            Section(header: Text("引擎")) {
                statusRow("状态", engine.status.label, highlight: true)
                statusRow("二进制", "libqemu-arm 未链接")
                statusRow("TCG 后端", "待接入 (TCI / TCTI)")
            }

            Section(header: Text("本次构建")) {
                statusRow("版本", "\(bundleInfo("CFBundleShortVersionString")) (\(bundleInfo("CFBundleVersion")))")
                statusRow("Bundle ID", bundleInfo("CFBundleIdentifier"))
                statusRow("最低系统", bundleInfo("MinimumOSVersion"))
                statusRow("签名", "未签名 / 侧载")
                statusRow("架构", "arm64")
            }

            Section(header: Text("显示表面")) {
                EngineHostView()
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                Text("移植完成后，QEMU 的 DisplaySurface 将在此视图上呈现。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("当前进度")) {
                Text("本 IPA 是「应用外壳 + 移植脚手架」，尚不包含可运行的 qemu-ios 模拟器。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("已完成：Tuist 工程、未签名 arm64 打包流水线、Release 自动发布、引擎源码锁定、Swift 抽象层。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("未完成：QEMU 交叉编译、依赖库 iOS 化、设备模型 rebase、单进程化改造。见 docs/PORTING.md。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("iOiEmulator")
    }

    private func statusRow(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(highlight ? .orange : .secondary)
        }
    }

    private func bundleInfo(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "—"
    }
}

private struct BoardListView: View {
    var body: some View {
        List {
            Section(header: Text("qemu-ios 的 8 块板子（目录数据，尚不可启动）")) {
                ForEach(BoardCatalog.all) { board in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(board.device).font(.headline)
                        Text("\(board.machine) · \(board.boardId) · \(board.soc) · \(board.guestArch)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(board.firmware)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text("固件需由使用者自行从 Apple IPSW 制备；本仓库与 IPA 均不含任何 Apple 固件或解密组件。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("设备目录")
    }
}

private struct GuideView: View {
    var body: some View {
        List {
            Section(header: Text("安装未签名 IPA")) {
                guideRow("TrollStore", "iOS 14.0–16.6.1 / 17.0 可用。IPA 已用 ldid 做 ad-hoc 伪签名，可直接导入安装。")
                guideRow("AltStore / SideStore", "用自己的 Apple ID 证书重签后安装；免费证书 7 天有效期。")
                guideRow("Sideloadly / 爱思助手", "用自己的开发证书重签后安装。")
            }
            Section(header: Text("JIT（可选）")) {
                guideRow("StikDebug", "iOS 17.4–26.x，配合 get-task-allow + ptrace 打开动态代码签名；每次启动需重新挂载。")
                guideRow("不启用 JIT", "退回 TCI / TCTI 解释器后端；项目实测约 3.3–5.2 倍减速，仍可用。")
            }
            Section(header: Text("注意")) {
                guideRow("固件", "App 内不含 iOS 固件；IPSW 制备需在受控环境完成。")
                guideRow("分发", "仅限自用侧载，不可上架 App Store（见 docs/PORTING.md）。")
            }
        }
        .navigationTitle("侧载说明")
    }

    private func guideRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline).bold()
            Text(detail).font(.footnote).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
