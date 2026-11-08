import Foundation

// =============================================================================
// firmwarekit 的 iOS 进程内 C ABI 绑定（wrapper 见 firmware-kit/src/lib.rs）。
//
// 上游桌面 / Android 把 firmwarekit 作为独立程序跑（JSON Lines 走 stdout）；
// iOS 普通 App 不能 fork/exec 捆绑的可执行文件，因此以 libltfw.a 链进 App，
// 事件经 C 函数指针回调直通本文件。
// =============================================================================

@_silgen_name("ltfw_abi_version")
func c_ltfw_abi_version() -> UInt32

@_silgen_name("ltfw_create")
func c_ltfw_create(_ catalog: UnsafePointer<CChar>,
                   _ id: UnsafePointer<CChar>,
                   _ ipsw: UnsafePointer<CChar>,
                   _ outDir: UnsafePointer<CChar>,
                   _ bootrom: UnsafePointer<CChar>?,
                   _ guestTools: UnsafePointer<CChar>?,
                   _ siblingIpsw: UnsafePointer<CChar>?,
                   _ cb: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void)?,
                   _ opaque: UnsafeMutableRawPointer?,
                   _ err: UnsafeMutablePointer<CChar>?,
                   _ errLen: Int) -> Int32

/// 每次制备的回调上下文：Rust 线程 → 主线程 @Published。
final class FirmwarePrepareContext {
    let onEvent: (String) -> Void
    init(onEvent: @escaping (String) -> Void) { self.onEvent = onEvent }

    func handle(_ line: String) { onEvent(line) }
}

private func ltfwEventTrampoline(_ opaque: UnsafeMutableRawPointer?, _ line: UnsafePointer<CChar>?) {
    guard let opaque, let line else { return }
    let context = Unmanaged<FirmwarePrepareContext>.fromOpaque(opaque).takeUnretainedValue()
    context.handle(String(cString: line))
}

enum FirmwareKit {
    static var abiVersion: UInt32 { c_ltfw_abi_version() }

    /// 制备一台设备。阻塞调用，必须放到后台线程。
    /// - Parameters:
    ///   - catalogPath: firmware-catalog.json 的文件路径（App 内置资源）
    ///   - entryID: 条目 id（如 n45ap-3A101a）
    ///   - ipswPath: 使用者自备的 IPSW
    ///   - outDir: 设备输出目录
    ///   - bootromPath: 可选的 SecureROM 镜像（n45/iPod1,1 启动期需要）
    ///   - siblingIpswPath: 可选姊妹 IPSW（keybag_ramdisk_from，iOS4+ 机型）
    ///   - onEvent: JSON 行事件（begin/step/progress/warning/error/done）
    /// - Returns: 0 成功；失败抛出错误消息。
    static func create(catalogPath: String, entryID: String, ipswPath: String,
                       outDir: String, bootromPath: String?, siblingIpswPath: String?,
                       onEvent: @escaping (String) -> Void) throws {
        let context = FirmwarePrepareContext(onEvent: onEvent)
        let opaque = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged.passUnretained(context).release() }

        var err = [CChar](repeating: 0, count: 1024)
        let rc = catalogPath.withCString { cat in
            entryID.withCString { id in
                ipswPath.withCString { ipsw in
                    outDir.withCString { out in
                        c_ltfw_create(cat, id, ipsw, out,
                                      bootromPath?.cString(using: .utf8),
                                      nil,
                                      siblingIpswPath?.cString(using: .utf8),
                                      ltfwEventTrampoline, opaque, &err, err.count)
                    }
                }
            }
        }
        guard rc == 0 else {
            let message = String(cString: err)
            throw FirmwareError.prepareFailed(message.isEmpty ? "firmwarekit 退出码 \(rc)" : message)
        }
    }
}

enum FirmwareError: LocalizedError {
    case prepareFailed(String)
    case shaMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .prepareFailed(let message):
            return "制备失败：\(message)"
        case .shaMismatch(expected: let expected, actual: let actual):
            return "IPSW 校验失败：SHA1 不匹配（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）"
        }
    }
}
