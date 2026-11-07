import SwiftUI
import UIKit
import CoreGraphics

// =============================================================================
// 真实显示表面：按屏幕刷新率轮询 qemu_ios_ui_frame()，把紧密打包的 BGRA
// 像素复制成 CGImage 交给 UIImageView。
//
// 之所以复制一次而不是零拷贝：qemu-ios-ui.h 明确说明 pixels 指针只在「再几帧」
// 内有效且永不 free，直接交给 CGDataProvider 有悬垂风险。
// guest 是 GLES 1.1 固定功能管线，iOS 的 OpenGLES.framework 至今仍完整提供，
// 因此这里不需要 Metal 转译（见 docs/PORTING.md）。
// =============================================================================
struct QemuEngineHostView: UIViewRepresentable {
    let engine: QemuEngineBridge = .shared

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        container.clipsToBounds = true

        let imageView = UIImageView(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let hint = UILabel()
        hint.text = "等待引擎输出首帧…"
        hint.textColor = .white.withAlphaComponent(0.7)
        hint.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let coordinator = context.coordinator
        coordinator.imageView = imageView
        coordinator.hint = hint
        coordinator.engine = engine
        coordinator.start()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var imageView: UIImageView?
        weak var hint: UILabel?
        var engine: QemuEngineBridge?
        private var displayLink: CADisplayLink?
        private var serial: UInt64 = 0

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFramesPerSecond = 30
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        deinit { displayLink?.invalidate() }

        @objc private func tick() {
            guard let frame = engine?.latestFrame(lastSerial: serial) else { return }
            serial = frame.serial
            guard frame.width > 0, frame.height > 0 else { return }

            let w = frame.width, h = frame.height
            let bitmapInfo = CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue |
                CGBitmapInfo.byteOrder32Little.rawValue)
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo.rawValue),
                  let dst = ctx.data else { return }
            memcpy(dst, frame.pixels, w * h * 4)
            guard let cg = ctx.makeImage() else { return }
            imageView?.image = UIImage(cgImage: cg)
            hint?.isHidden = true
        }
    }
}
