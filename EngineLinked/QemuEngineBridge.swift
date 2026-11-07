import Foundation
import UIKit

// =============================================================================
// qemu-ios 的 iOS 宿主 ABI 绑定。
//
// 头文件：qemu-ios/contrib/ios-app/qemu-ios-ui.h（v0.0.13，52 个 qemu_ios_* 符号）
// 用 @_silgen_name 直接声明 C 函数，避免引入 modulemap；
// 这些符号由 build-engine-lib.sh 归档进 libqemu-arm.a。
//
// 本文件仅在 engine/prebuilt/libqemu-arm.a 存在时由 Project.swift 纳入编译，
// 因此未链接引擎的外壳 IPA 不会因缺少符号而链接失败。
// =============================================================================

@_silgen_name("qemu_ios_main")
private func c_qemu_ios_main(_ argc: Int32,
                             _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

@_silgen_name("qemu_ios_ui_frame")
private func c_qemu_ios_ui_frame(_ pixels: UnsafeMutablePointer<UnsafeRawPointer?>,
                                 _ width: UnsafeMutablePointer<Int32>,
                                 _ height: UnsafeMutablePointer<Int32>,
                                 _ serial: UnsafeMutablePointer<UInt64>) -> Bool

@_silgen_name("qemu_ios_ui_frame_size")
private func c_qemu_ios_ui_frame_size(_ width: UnsafeMutablePointer<Int32>,
                                      _ height: UnsafeMutablePointer<Int32>)

@_silgen_name("qemu_ios_ui_touch")
private func c_qemu_ios_ui_touch(_ slot: Int32, _ phase: Int32,
                                 _ nx: Double, _ ny: Double)

@_silgen_name("qemu_ios_ui_button")
private func c_qemu_ios_ui_button(_ button: Int32, _ down: Bool)

@_silgen_name("qemu_ios_ui_ready")
private func c_qemu_ios_ui_ready() -> Bool

@_silgen_name("qemu_ios_ui_paused")
private func c_qemu_ios_ui_paused() -> Bool

@_silgen_name("qemu_ios_ui_vm_started")
private func c_qemu_ios_ui_vm_started()

@_silgen_name("qemu_ios_ui_vm_stopped")
private func c_qemu_ios_ui_vm_stopped()

@_silgen_name("qemu_ios_snapshot_save2")
private func c_qemu_ios_snapshot_save2(_ path: UnsafePointer<CChar>)

@_silgen_name("qemu_ios_snapshot_resume")
private func c_qemu_ios_snapshot_resume()

@_silgen_name("qemu_ios_set_foreground")
private func c_qemu_ios_set_foreground(_ foreground: Bool)

@_silgen_name("qemu_ios_ui_cancel_input")
private func c_qemu_ios_ui_cancel_input()

/// 把 libqemu-arm 的 C ABI 包装成 Swift 侧的 EmulatorEngine。
/// 注意：QEMU 一个进程只能启动一次（qemu-ios-ui.h 明确说明），因此用单例。
final class QemuEngineBridge: EmulatorEngine, @unchecked Sendable {

    static let shared = QemuEngineBridge()

    private let lock = NSLock()
    private var _status: EngineStatus = .notLinked
    private var launched = false
    private var pendingSnapshot: String?

    private(set) var frameWidth: Int = 0
    private(set) var frameHeight: Int = 0

    var status: EngineStatus {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    private init() {
        var w: Int32 = 0, h: Int32 = 0
        c_qemu_ios_ui_frame_size(&w, &h)
        frameWidth = Int(w)
        frameHeight = Int(h)
        _status = .notLinked
    }

    func start(machine: String, nandPath: String) throws {
        lock.lock()
        if launched {
            lock.unlock()
            throw EngineError.alreadyLaunched
        }
        launched = true
        _status = .loading
        lock.unlock()

        // qemu_ios_main 会占用调用线程直到 VM 停止，必须放在后台线程。
        // App 主线程留给 UIKit / SwiftUI。
        let args = QemuEngineBridge.makeArguments(machine: machine, nandPath: nandPath,
                                                  snapshot: pendingSnapshot)
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = c_qemu_ios_main(Int32(args.count), QemuEngineBridge.cArgv(args))
            DispatchQueue.main.async {
                self.lock.lock()
                self._status = rc == 0 ? .running(machine: machine) : .failed("qemu_ios_main rc=\(rc)")
                self.lock.unlock()
            }
        }
        c_qemu_ios_ui_vm_started()
        c_qemu_ios_set_foreground(true)
    }

    func stop() {
        c_qemu_ios_ui_cancel_input()
        c_qemu_ios_ui_vm_stopped()
        lock.lock(); _status = .notLinked; lock.unlock()
    }

    func sendTouch(x: Double, y: Double, phase: GuestTouchPhase) {
        let p: Int32
        switch phase {
        case .began:  p = 0   // QEMU_IOS_TOUCH_BEGIN
        case .moved:  p = 1   // QEMU_IOS_TOUCH_UPDATE
        case .ended:  p = 2   // QEMU_IOS_TOUCH_END
        }
        c_qemu_ios_ui_touch(0, p, x, y)
    }

    func restoreSnapshot(at path: String) throws {
        pendingSnapshot = path
        c_qemu_ios_snapshot_resume()
    }

    /// 取最新一帧（紧密打包 BGRA）。返回 false 表示没有新帧。
    func latestFrame(lastSerial: UInt64) -> (pixels: UnsafeRawPointer, width: Int, height: Int, serial: UInt64)? {
        var pixels: UnsafeRawPointer?
        var w: Int32 = 0, h: Int32 = 0
        var serial = lastSerial
        guard c_qemu_ios_ui_frame(&pixels, &w, &h, &serial), let p = pixels else { return nil }
        return (p, Int(w), Int(h), serial)
    }

    var isReady: Bool { c_qemu_ios_ui_ready() }
    var isPaused: Bool { c_qemu_ios_ui_paused() }

    // MARK: - 参数构造

    /// QEMU 命令行。固件/NAND 路径由使用者通过 Files App 导入，仓库与 IPA 均不含固件。
    static func makeArguments(machine: String, nandPath: String, snapshot: String?) -> [String] {
        var a = ["iOiEmulator",
                 "-M", machine,
                 "-display", "none",
                 "-m", "128",
                 "-snapshot",
                 "-rtc", "base=localtime"]
        if !nandPath.isEmpty {
            a += ["-drive", "file=\(nandPath),format=raw,if=none,id=nand"]
        }
        if let snapshot = snapshot {
            a += ["-incoming", "file:\(snapshot)"]
        }
        return a
    }

    /// 把 Swift 字符串数组转成 C argv，并保持在进程生命周期内有效。
    private static var argvStorage: [UnsafeMutablePointer<CChar>?] = []
    private static func cArgv(_ args: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        argvStorage = args.map { strdup($0) }
        let buf = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argvStorage.count + 1)
        buf.initialize(from: argvStorage, count: argvStorage.count)
        buf[argvStorage.count] = nil
        return buf
    }
}
