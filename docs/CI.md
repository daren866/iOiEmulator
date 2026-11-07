# GitHub Actions 打包流水线

## 触发方式

`.github/workflows/build-unsigned-ipa.yml`：

| 事件 | 行为 |
| --- | --- |
| 任意分支 `push`（有新提交） | 自动构建未签名 arm64 IPA，并发布到 Releases |
| `workflow_dispatch` | 手动触发，同上 |
| tag 推送 | **显式忽略**（`tags-ignore: ['**']`） |

忽略 tag 是必要的：工作流自己会创建 `build-N` tag 与 Release，
若 tag 推送也触发构建会造成无限循环。

`concurrency` 按 `github.ref` 分组并取消进行中的旧构建，避免并发浪费 macOS runner。

## 流水线各阶段

1. **Checkout** — `fetch-depth: 0`，保留完整历史便于写入构建信息。
2. **Show toolchain** — 打印 macOS / Xcode / iPhoneOS SDK 版本。
3. **Install Tuist and ldid** — Homebrew 装 Tuist（失败则回退官方安装脚本）；`ldid` 可选，缺失时只产出纯未签名 IPA。
4. **Generate Xcode project** — `tuist generate --no-open`，断言 `.xcworkspace` 已生成。
5. **Build unsigned arm64 archive** — 关键参数：

   ```
   -destination generic/platform=iOS
   CODE_SIGNING_ALLOWED=NO
   CODE_SIGNING_REQUIRED=NO
   CODE_SIGN_IDENTITY=""
   ARCHS=arm64
   IPHONEOS_DEPLOYMENT_TARGET=15.0
   SKIP_INSTALL=NO
   ```

   `SKIP_INSTALL=NO` 保证 `.app` 落在 `*.xcarchive/Products/Applications/`。
6. **Verify archive binary** — `lipo` 确认 arm64、`file` 确认 Mach-O、`codesign -dv` 预期显示未签名。
7. **Package IPA** — 调用 `scripts/package-ipa.sh`：`chmod +x` → 可选 `ldid -S` 伪签名 →
   `Payload/` → `zip` → `SHA256SUMS` + `build-info.txt`。
8. **IPA sanity check** — `unzip -t` 校验包完整、`unzip -l` 确认主二进制路径。
9. **Upload to Actions Artifacts** — 备份，保留 14 天。
10. **Publish IPA to Releases** — `softprops/action-gh-release@v2`。

## Releases 策略

每次成功构建发布一个 **prerelease**：

- tag：`build-<run_number>`（单调递增，不会重复）
- Release 名：`iOiEmulator 未签名 IPA · build #N`
- 附件：`*.ipa`、`SHA256SUMS`、`build-info.txt`
- Release 正文含 commit / 分支 / 文件名 / 引擎状态

`run_number` 在全仓库唯一，因此即使同一分支连续提交也不会覆盖；
重新运行同一 run 时该 action 会更新已有 Release 而非报错。

`permissions: contents: write` 是发布 Release 所必需的，
使用 GitHub 自动提供的 `secrets.GITHUB_TOKEN`，**不需要在仓库里配置任何 PAT**。

## 关于密钥

- CI 端只使用 `GITHUB_TOKEN`，无长期凭据。
- 推送代码用的个人访问令牌属于本地操作，不应写入任何仓库文件、脚本或 workflow。
- 若需要 CI 触发其他仓库，请在 Settings → Secrets 里添加，不要硬编码。

## 本地复现（需 macOS + Xcode）

```bash
just generate
just archive-unsigned        # 或：bash scripts/package-ipa.sh
```

打包脚本 `scripts/package-ipa.sh` 与 CI 完全共用，可通过环境变量覆盖：

```bash
ARCHIVE_PATH=... IPA_DIR=... IPA_NAME=... bash scripts/package-ipa.sh
```

## 常见失败与排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `tuist: command not found` | Homebrew 与官方脚本都失败；检查 runner 网络，或在日志里看 fallback 是否执行 |
| `未生成 xcworkspace` | `Project.swift` 语法与 Tuist 版本不匹配；`Tuist.swift` / `Tuist/Package.swift` 用的是 Tuist 4.x API |
| `archive 中没有 .app` | 缺少 `SKIP_INSTALL=NO`，或 scheme 未共享 |
| 二进制不是 arm64 | 检查 `ARCHS=arm64` 是否被 `ONLY_ACTIVE_ARCH` 覆盖 |
| Release 上传 403 | 缺 `permissions: contents: write` |
| 每次 push 触发两次构建 | 检查是否有别的 workflow 也监听了 tag 推送 |
