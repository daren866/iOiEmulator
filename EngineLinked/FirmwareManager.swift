import Foundation
import CryptoKit

/// firmware-catalog.json 的元数据模型。仓库与 App 只含 URL / SHA1 / 尺寸等清单，
/// 不含任何 Apple 固件；IPSW 由使用者通过 App 内下载（Apple 公开 CDN / 镜像）或导入。
struct FirmwareCatalogDocument: Codable {
    let format: Int
    let entries: [FirmwareEntry]
}

struct FirmwareEntry: Codable, Identifiable, Hashable {
    let id: String           // 如 n45ap-3A101a
    let board: String        // 如 n45ap
    let product_type: String // 如 iPod1,1
    let version: String
    let build: String
    let released: String?
    let status: String?
    let source: FirmwareSource?
}

struct FirmwareSource: Codable, Hashable {
    let url: String?
    let sha1: String?
    let bytes: Int?
    let mirrors: [FirmwareMirror]?
}

struct FirmwareMirror: Codable, Hashable {
    let url: String
    let sha1: String?
    let bytes: Int?
}

/// 制备完成、可供启动的设备包（设备目录由 firmwarekit create 产出）。
struct DeviceBundle: Identifiable, Hashable {
    let entryID: String
    let dir: URL
    let machine: String?      // n45ap → iPod-Touch-1G（来自 BoardCatalog）
    let hasIBoot: Bool
    let hasNand: Bool
    var id: String { entryID }
    var ready: Bool { hasIBoot && hasNand && machine != nil }
}

/// 固件导入 / 制备管理器。文档目录布局：
///   Documents/Downloads/<entryID>.ipsw     下载或导入的 IPSW
///   Documents/Bootrom/<board>.bin          使用者自备的 SecureROM（如 bootrom_s5l8900）
///   Documents/Devices/<entryID>/           firmwarekit create 产出的设备目录
///   Documents/Devices/<entryID>-rw/        guest NAND 写入 overlay（启动参数 nand-overlay=）
@MainActor
final class FirmwareManager: NSObject, ObservableObject {
    static let shared = FirmwareManager()

    @Published private(set) var entries: [FirmwareEntry] = []
    @Published private(set) var devices: [DeviceBundle] = []
    @Published private(set) var downloadProgress: [String: Double] = [:]     // entryID → 0...1
    @Published private(set) var preparingIDs: Set<String> = []
    @Published var prepareLog: [String] = []
    @Published var lastError: String?

    private let fileManager = FileManager.default
    private var downloads: [String: URLSessionDownloadTask] = [:]

    // MARK: - 目录

    var downloadsDir: URL  { docs.appendingPathComponent("Downloads", isDirectory: true) }
    var bootromDir: URL    { docs.appendingPathComponent("Bootrom", isDirectory: true) }
    var devicesDir: URL    { docs.appendingPathComponent("Devices", isDirectory: true) }
    var catalogURL: URL?   { Bundle.main.url(forResource: "firmware-catalog", withExtension: "json") }
    private var docs: URL  { fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private init() {
        for dir in [downloadsDir, bootromDir, devicesDir] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        loadCatalog()
        rescanDevices()
    }

    func loadCatalog() {
        guard let url = catalogURL, let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(FirmwareCatalogDocument.self, from: data) else {
            lastError = "内置固件目录清单解析失败"
            return
        }
        entries = doc.entries
    }

    func entry(for id: String) -> FirmwareEntry? { entries.first { $0.id == id } }

    func machine(forBoard board: String) -> String? {
        BoardCatalog.all.first { $0.boardId == board }?.machine
    }

    // MARK: - IPSW 获取（下载或导入）

    /// 使用者从文件 App 导入的 IPSW。targetID 用于放置到预期的文件名。
    func importIPSW(at source: URL, for entry: FirmwareEntry) throws {
        let dest = downloadsDir.appendingPathComponent("\(entry.id).ipsw")
        if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try fileManager.copyItem(at: source, to: dest)
        try verifySHA1(dest, expected: entry.source?.sha1)
    }

    func download(_ entry: FirmwareEntry) {
        guard downloads[entry.id] == nil,
              let primary = entry.source?.url else { return }
        let urls: [String] = [primary] + (entry.source?.mirrors?.map(\.url) ?? [])
        startDownload(entry, urls: urls)
    }

    private func startDownload(_ entry: FirmwareEntry, urls: [String]) {
        guard let url = URL(string: urls[0]) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let task = URLSession.shared.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }
            Task { @MainActor in
                self.finishDownload(entry, urls: urls, location: location, error: error, status:
                    (response as? HTTPURLResponse)?.statusCode)
            }
        }
        task.delegate = self
        downloads[entry.id] = task
        downloadProgress[entry.id] = 0
        task.resume()
    }

    private func finishDownload(_ entry: FirmwareEntry, urls: [String], location: URL?,
                                error: Error?, status: Int?) {
        downloads[entry.id] = nil
        defer { if downloadProgress[entry.id] != nil { downloadProgress[entry.id] = nil } }
        guard error == nil, let location, (200..<300).contains(status ?? 0) else {
            var rest = urls; rest.removeFirst()
            if !rest.isEmpty { startDownload(entry, urls: rest) }          // 镜像回退
            else { lastError = "\(entry.id) 下载失败：\(error?.localizedDescription ?? "HTTP \(status ?? 0)")" }
            return
        }
        let dest = downloadsDir.appendingPathComponent("\(entry.id).ipsw")
        try? fileManager.removeItem(at: dest)
        do {
            try fileManager.moveItem(at: location, to: dest)
            try verifySHA1(dest, expected: entry.source?.sha1)
        } catch {
            lastError = "\(entry.id) 校验失败：\(error.localizedDescription)"
            try? fileManager.removeItem(at: dest)
        }
    }

    private func verifySHA1(_ url: URL, expected: String?) throws {
        guard let expected, !expected.isEmpty else { return }
        let data = try Data(contentsOf: url)
        let digest = Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else {
            try? fileManager.removeItem(at: url)
            throw FirmwareError.shaMismatch(expected: expected, actual: digest)
        }
    }

    func localIPSW(for entry: FirmwareEntry) -> URL? {
        let url = downloadsDir.appendingPathComponent("\(entry.id).ipsw")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func removeIPSW(for entry: FirmwareEntry) {
        let url = downloadsDir.appendingPathComponent("\(entry.id).ipsw")
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Bootrom（SecureROM，使用者自备）

    func importBootrom(at source: URL, for board: String) throws {
        let dest = bootromDir.appendingPathComponent("\(board).bin")
        if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try fileManager.copyItem(at: source, to: dest)
    }

    func bootrom(for board: String) -> URL? {
        let url = bootromDir.appendingPathComponent("\(board).bin")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 制备

    func prepare(_ entry: FirmwareEntry) {
        guard let ipsw = localIPSW(for: entry),
              let catalog = catalogURL else {
            lastError = "缺少 IPSW 或固件目录清单"
            return
        }
        let out = devicesDir.appendingPathComponent(entry.id, isDirectory: true)
        try? fileManager.removeItem(at: out)
        try? fileManager.createDirectory(at: out, withIntermediateDirectories: true)

        preparingIDs.insert(entry.id)
        prepareLog.append("== \(entry.id) 开始制备")
        let bootrom = bootrom(for: entry.board)?.path
        let catalogPath = catalog.path
        let ipswPath = ipsw.path
        let outPath = out.path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try FirmwareKit.create(catalogPath: catalogPath, entryID: entry.id,
                                       ipswPath: ipswPath, outDir: outPath,
                                       bootromPath: bootrom, siblingIpswPath: nil,
                                       onEvent: { line in
                                           DispatchQueue.main.async {
                                               self?.prepareLog.append(line)
                                           }
                                       })
                DispatchQueue.main.async {
                    self?.preparingIDs.remove(entry.id)
                    self?.prepareLog.append("== \(entry.id) 制备完成")
                    self?.rescanDevices()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.preparingIDs.remove(entry.id)
                    self?.lastError = error.localizedDescription
                    self?.prepareLog.append("!! \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 设备扫描 / 删除

    func rescanDevices() {
        var bundles: [DeviceBundle] = []
        let ids = (try? fileManager.contentsOfDirectory(atPath: devicesDir.path)) ?? []
        for id in ids.sorted() {
            let dir = devicesDir.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  !id.hasSuffix("-rw") else { continue }
            let entry = entry(for: id)
            bundles.append(DeviceBundle(
                entryID: id,
                dir: dir,
                machine: entry.flatMap { machine(forBoard: $0.board) },
                hasIBoot: fileManager.fileExists(atPath: dir.appendingPathComponent("iBoot.bin").path),
                hasNand: fileManager.fileExists(atPath: dir.appendingPathComponent("nand", isDirectory: true).path)
            ))
        }
        devices = bundles
    }

    func removeDevice(_ bundle: DeviceBundle) {
        try? fileManager.removeItem(at: bundle.dir)
        try? fileManager.removeItem(at: devicesDir.appendingPathComponent("\(bundle.entryID)-rw"))
        rescanDevices()
    }

    /// iPod-Touch-1G / iPhone-2G（n45/m68 机器）的启动机器选项。
    /// 引擎要求：-M <machine>,bootrom=…,iboot=…,nand=…,nand-overlay=…（见 hw/arm/ipod_touch_1g.c）。
    func machineOptions(for bundle: DeviceBundle, bootrom: URL?) -> String? {
        guard let machine = bundle.machine else { return nil }
        let iboot = bundle.dir.appendingPathComponent("iBoot.bin").path
        let nand = bundle.dir.appendingPathComponent("nand").path
        let overlay = devicesDir.appendingPathComponent("\(bundle.entryID)-rw", isDirectory: true)
        try? fileManager.createDirectory(at: overlay, withIntermediateDirectories: true)
        guard let bootrom else { return nil }   // 引擎硬性要求 bootrom=
        return "\(machine),bootrom=\(bootrom.path),iboot=\(iboot),nand=\(nand),nand-overlay=\(overlay.path)"
    }
}

// MARK: - 下载进度

extension FirmwareManager: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                                totalBytesExpectedToSend: Int64) {}
}

extension FirmwareManager {
    /// 简易进度：靠 expected bytes 与已写文件长度之差实现精确进度较繁琐，
    /// 这里用 downloadTask 的 countOfBytesReceived 直接观察（Task 句柄在 downloads 里）。
    func tickProgress() {
        for (id, task) in downloads {
            let received = task.countOfBytesReceived
            let expected = task.countOfBytesExpectedToReceive
            if expected > 0 {
                downloadProgress[id] = Double(received) / Double(expected)
            }
        }
    }
}
