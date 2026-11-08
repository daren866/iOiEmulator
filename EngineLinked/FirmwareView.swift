import SwiftUI
import UniformTypeIdentifiers

/// 固件 tab：浏览内置固件目录清单（URL/SHA1 元数据）→ 下载或导入自备 IPSW →
/// 进程内 firmwarekit 制备设备 → 选 bootrom → 启动。
/// 仓库与 App 不含 Apple 固件；IPSW 与 SecureROM 均由使用者提供。
struct FirmwareView: View {
    @StateObject private var manager = FirmwareManager.shared
    @State private var importingIPSWFor: FirmwareEntry?
    @State private var importingBootromBoard: String?
    @State private var started: String?

    var body: some View {
        List {
            if let error = manager.lastError {
                Section { Text(error).foregroundColor(.red).font(.footnote) }
            }

            Section(header: Text("制备说明")) {
                Text("① 选一个版本下载（或从文件 App 导入你已下载的 IPSW）。")
                Text("② 导入对应机型的 SecureROM（bootrom）镜像。")
                Text("③ 点「制备」：进程内 firmwarekit 解密 IPSW 并生成设备目录。")
                Text("④ 制备完成后点「启动」。本仓库与 IPA 不含任何 Apple 固件。")
                    .foregroundColor(.secondary)
            }

            deviceSection

            firmwareSection
        }
        .navigationTitle("固件")
        .onAppear { manager.rescanDevices() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            manager.tickProgress()
        }
        .fileImporter(isPresented: Binding(get: { importingIPSWFor != nil }, set: { if !$0 { importingIPSWFor = nil } }),
                      allowedContentTypes: [.zip, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first, let entry = importingIPSWFor {
                do { try manager.importIPSW(at: url, for: entry) }
                catch { manager.lastError = "导入失败：\(error.localizedDescription)" }
            }
            importingIPSWFor = nil
        }
        .fileImporter(isPresented: Binding(get: { importingBootromBoard != nil }, set: { if !$0 { importingBootromBoard = nil } }),
                      allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first, let board = importingBootromBoard {
                do { try manager.importBootrom(at: url, for: board) }
                catch { manager.lastError = "导入失败：\(error.localizedDescription)" }
            }
            importingBootromBoard = nil
        }
    }

    // MARK: - 设备列表

    @ViewBuilder
    private var deviceSection: some View {
        Section(header: Text("已制备设备")) {
            if manager.devices.isEmpty {
                Text("还没有制备好的设备。").foregroundColor(.secondary).font(.footnote)
            }
            ForEach(manager.devices) { bundle in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(bundle.entryID).font(.headline)
                        Spacer()
                        if bundle.ready {
                            Button("启动") { start(bundle) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        } else {
                            Text("不完整").font(.caption).foregroundColor(.orange)
                        }
                    }
                    Text(bundle.machine ?? "未知机型")
                        .font(.caption).foregroundColor(.secondary)
                    bootromRow(bundle)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func bootromRow(_ bundle: DeviceBundle) -> some View {
        let board = boardID(for: bundle)
        let has = manager.bootrom(for: board) != nil
        HStack {
            Image(systemName: has ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(has ? .green : .orange)
                .font(.caption)
            Text(has ? "bootrom 已导入" : "需导入 \(board) 的 SecureROM")
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Button(has ? "更换" : "导入") { importingBootromBoard = board }
                .controlSize(.small)
        }
    }

    private func boardID(for bundle: DeviceBundle) -> String {
        manager.entry(for: bundle.entryID)?.board ?? "n45ap"
    }

    private func start(_ bundle: DeviceBundle) {
        let board = boardID(for: bundle)
        guard let bootrom = manager.bootrom(for: board),
              let options = manager.machineOptions(for: bundle, bootrom: bootrom) else {
            manager.lastError = "缺少 bootrom，无法启动（引擎硬性要求 bootrom= 机器选项）"
            return
        }
        do {
            started = bundle.entryID
            try makeEngine().start(machineOptions: options)
        } catch {
            manager.lastError = "启动失败：\(error.localizedDescription)"
            started = nil
        }
    }

    // MARK: - 固件目录

    private var firmwareSection: some View {
        Section(header: Text("固件目录（\(manager.entries.count) 个版本）")) {
            ForEach(supportedEntries) { entry in
                entryRow(entry)
            }
            if manager.entries.count > supportedEntries.count {
                Text("其余 \(manager.entries.count - supportedEntries.count) 个版本的机型启动参数尚未适配（可制备、暂不可启动）。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// 首批支持启动的机型：n45ap（iPod touch 1G / iPhone 初代，iPhone OS 1.x）。
    private var supportedEntries: [FirmwareEntry] {
        manager.entries.filter { ["n45ap", "m68ap"].contains($0.board) }
    }

    @ViewBuilder
    private func entryRow(_ entry: FirmwareEntry) -> some View {
        let ipsw = manager.localIPSW(for: entry)
        let progress = manager.downloadProgress[entry.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(entry.product_type) \(entry.version)").font(.headline)
                Spacer()
                statusView(entry, ipsw: ipsw, progress: progress)
            }
            Text("\(entry.id) · \(entry.build) · \(entry.released ?? "")")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusView(_ entry: FirmwareEntry, ipsw: URL?, progress: Double?) -> some View {
        if manager.preparingIDs.contains(entry.id) {
            ProgressView().controlSize(.small)
            Text("制备中").font(.caption)
        } else if let p = progress {
            ProgressView(value: p).controlSize(.small).frame(width: 90)
        } else if ipsw != nil {
            Button("制备") { manager.prepare(entry) }.controlSize(.small)
            Menu("…") {
                Button("重新下载") { manager.download(entry) }
                Button("从文件导入") { importingIPSWFor = entry }
                Button("删除 IPSW", role: .destructive) { manager.removeIPSW(for: entry) }
            }
        } else {
            Button("下载") { manager.download(entry) }.controlSize(.small)
            Button("导入") { importingIPSWFor = entry }.controlSize(.small)
        }
    }
}

/// 与 ContentView.swift 的 makeEngine 一致；本文件在 EngineLinked/ 下仅随引擎构建编译。
private func makeEngine() -> EmulatorEngine {
    QemuEngineBridge.shared
}
