import Foundation

enum EngineStatus: Equatable {
    case notLinked
    case loading
    case running(machine: String)
    case failed(String)

    var label: String {
        switch self {
        case .notLinked: return "未接入（脚手架）"
        case .loading: return "加载中"
        case .running(let machine): return "运行中 · \(machine)"
        case .failed(let reason): return "失败 · \(reason)"
        }
    }
}

enum GuestTouchPhase {
    case began
    case moved
    case ended
}

/// 引擎抽象层。移植完成后由 `QemuEngineBridge` 实现，
/// 把 libqemu-arm 导出的 `qemu_ios_*` ABI 包装成 Swift 可调用接口。
protocol EmulatorEngine: AnyObject {
    var status: EngineStatus { get }
    var frameWidth: Int { get }
    var frameHeight: Int { get }
    /// machineOptions 形如 "iPod-Touch-1G,bootrom=…,iboot=…,nand=…,nand-overlay=…"，
    /// 作为单个 `-M` 参数传入（引擎硬性要求这些机器选项）。
    func start(machineOptions: String) throws
    func stop()
    func sendTouch(x: Double, y: Double, phase: GuestTouchPhase)
    func restoreSnapshot(at path: String) throws
}

/// 当前默认实现是显式占位：调用即报错，而不是伪装成"能跑的模拟器"。
final class UnavailableEngine: EmulatorEngine {
    private(set) var status: EngineStatus = .notLinked
    let frameWidth: Int = 0
    let frameHeight: Int = 0

    func start(machineOptions: String) throws {
        throw EngineError.notLinked
    }

    func stop() {}

    func sendTouch(x: Double, y: Double, phase: GuestTouchPhase) {}

    func restoreSnapshot(at path: String) throws {
        throw EngineError.notLinked
    }
}

enum EngineError: LocalizedError {
    case notLinked
    case alreadyLaunched
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .notLinked:
            return "libqemu-arm 尚未编译进本 App。请按 docs/PORTING.md 完成引擎移植。"
        case .alreadyLaunched:
            return "QEMU 一个进程只能启动一次（qemu-ios-ui.h 约束），请重启 App。"
        case .invalidFrame:
            return "引擎返回的帧缓冲无效。"
        }
    }
}
