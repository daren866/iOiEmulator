set dotenv-load := true
set shell := ["bash", "-eo", "pipefail", "-c"]

project_name := "iOiEmulator"
default_scheme := "iOiEmulator"
simulator_device := "iPhone 17 Pro"
simulator_os := "26.2"

alias b := build
alias t := test
alias o := open
alias a := archive-unsigned

default:
    @just --list

# 生成 Xcode 工程（CI 也用这一条）
[group('ios')]
generate:
    tuist generate --no-open

# 模拟器构建
[group('ios')]
build scheme=default_scheme device=simulator_device os=simulator_os: (generate)
    tuist xcodebuild build -workspace {{ project_name }}.xcworkspace -scheme {{ scheme }} -destination 'platform=iOS Simulator,name={{ device }},OS={{ os }}'

# 单元测试
[group('ios')]
test scheme=default_scheme device=simulator_device os=simulator_os: (generate)
    tuist test {{ scheme }} --device "{{ device }}" --os "{{ os }}" --no-selective-testing

[group('ios')]
open: (generate)
    open {{ project_name }}.xcworkspace

# 本地产出未签名 arm64 archive（与 CI 同一组参数）
[group('packaging')]
archive-unsigned: (generate)
    xcodebuild clean archive \
        -workspace {{ project_name }}.xcworkspace \
        -scheme {{ default_scheme }} \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$PWD/build/{{ project_name }}.xcarchive" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 \
        ENABLE_BITCODE=NO SKIP_INSTALL=NO COMPILER_INDEX_STORE_ENABLE=NO

# 把 archive 打成 IPA（CI 共用 scripts/package-ipa.sh）
[group('packaging')]
package:
    bash scripts/package-ipa.sh

# 一步到位：archive + 打包
[group('packaging')]
ipa: (archive-unsigned) (package)

# 校验下载引擎源码
[group('engine')]
fetch-engine:
    bash scripts/fetch-engine.sh

# 全链：源码校验 → iOS 依赖 sysroot → QEMU configure → libqemu-arm.a
[group('engine')]
engine:
    bash scripts/build-engine-ios.sh

# 兼容旧名字
[group('engine')]
engine-config: (engine)
