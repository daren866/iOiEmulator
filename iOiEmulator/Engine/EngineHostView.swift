import SwiftUI
import UIKit

/// 显示表面占位视图。
///
/// 移植 qemu-ios 后，这里替换为把 QEMU `DisplaySurface` 的像素缓冲
/// blit 到 `UIView`（或 `CAMetalLayer`）的实现；guest 侧是 GLES 1.1，
/// iOS 的 OpenGLES.framework 仍提供完整固定功能管线，无需 Metal 转译。
struct EngineHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = UIColor.black
        view.clipsToBounds = true

        let label = UILabel()
        label.text = "DisplaySurface 占位\n引擎尚未链接"
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
