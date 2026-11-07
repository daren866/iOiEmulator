# engine/

本目录存放**引擎源码的锁定清单**，不直接存放源码（体积 55 MB +，且属 GPL）。

- `SOURCES.json` — 两个 tarball 的仓库、tag、commit、字节数、SHA256、许可证。
- `vendor/` — `scripts/fetch-engine.sh` 的下载目的地，已被 `.gitignore` 忽略。
- `ios-build/` — `scripts/build-engine-ios.sh` 生成的交叉编译配置，同样被忽略。

```bash
# 从 GitHub（可走加速代理）拉取并校验
GH_PROXY=https://v4.gh-proxy.org/ bash scripts/fetch-engine.sh

# 解包
cd engine/vendor
tar xzf qemu-ios-v0.0.13-source.tar.gz
tar xzf LightTouch-v0.0.13-source.tar.gz
```

解包后的目录：

- `qemu-ios-lighttouch-v0.0.13/` — QEMU fork，含 `hw/arm/` 设备模型、
  `contrib/portable/` 打包脚本、`docs/research/ipod-touch-2g-on-iphone.md` 可行性研究。
- `LightTouch-v0.0.13/` — App 外壳，`Android/ Linux/ Windows/ macOS/ Portable/`
  以及 `docs/BUILD-PLAN.md`。

**不要把 Apple 固件、解密组件或制备好的 `.itbase` 放进本目录或提交到 git。**
