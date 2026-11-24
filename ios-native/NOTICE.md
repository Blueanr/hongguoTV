# 来源与许可证

本目录代码采用 GPL-3.0-only，许可证全文见仓库根目录 `LICENSE`。

- build 5 的 `DramaPlayback.swift` / `tooling/drama-session.js` 参考 `jackotom/hongguo-drama`（GPL-3.0-only），固定提交 `bc02370ff519adf7a94a20688c5538ac303f4ec7` 的 `scripts/sdk-playback/vendor/phone_account/phone_sdk_{bootstrap,exchange,materials}_v5.py`、`phone_playback_{request,signing}_v5.py` 与 `phone_account_device.py`。移植改动包括 Swift 原生传输、JavaScriptCore 算术、分支 12 有界选择、取消与缓存；未捆绑 Python/Unicorn 或原始 Android SDK。原始 SDK 资料由设备按哈希验证后下载，只用于配置/表读取。

- 当前播放解析依赖 `beilunyang/openhongguo` Swift Package **0.4.0**（tag 提交 `cd27b9ef42a4aa06859d12e5a24ba7653fa64a2c`），Copyright 2026 beilunyang，Apache-2.0。Go 运行时及 gomobile 生成代码遵循 Go BSD 许可证。两份许可证保存在 `licenses/` 并随应用资源分发。SDK 的预编译 XCFramework 由上游 Package.swift 的 SHA-256 校验。

- 内容协议、匿名设备注册、账号端点、媒体索引和解码移植自本仓库 `kotlin-tv/core`；其第三方来源见 `kotlin-tv/NOTICE.md`。
- 单集播放签名移植自 `PlayerSignature.kt`，按 `player-signing.json` 中独立 Go 参考向量逐字节校验；Argus/Simon 的 MIT 声明随应用内 `Kotlin-NOTICE.txt` 分发。
- 当前播放使用的 v5 算术移植自 `N3urda/hongguoTV` 提交 `ac3a1e2e866b2a917651575ba507adfe62344932` 下的 `Signer.kt`、`AesV3.kt`、`V5Constants.kt`（GPL-3.0-only）；独立合成向量来自同版本 `signing-v5-f13.json` 与 `signing-v5-carrier.json`。未复制 PolyForm 研究工具或嵌入官方 SDK。协议来源与验证说明见 `PROTOCOL_ALIGNMENT.md` 及上游 `SIGNING_V5.md`。
- 签名组件构建时提取 `server/vendor/hongguo.cjs` 的固定算法片段。该文件来源于 drpys，固定版本及原版权信息见 `server/vendor/NOTICE.md` 与 `server/vendor/LICENSE.drpys`。构建脚本仅调整会话 nonce／启动时间，并使用当前 Kotlin 版请求形态。
- 打包依赖 `buffer` 6.0.3：MIT，版权 Feross Aboukhadijeh 及贡献者。其许可证随构建安装的 `node_modules/buffer/LICENSE` 提供，并复制进应用资源。
- `esbuild` 为构建工具（MIT），不作为设备运行时嵌入。
- SwiftUI、AVFoundation、JavaScriptCore、CommonCrypto、Security 和 zlib 使用系统 SDK。
- build 11 使用原生 libmpv 0.39.0 与其 FFmpeg 等依赖，二进制来源及对应构建源码：https://github.com/gungun974/melodink-libmpv-darwin-build/tree/v0.39.0 。下载固定 SHA-256，设备和模拟器框架随 IPA 分发。倍速与渲染接入参考 PiliPlus `217fb54`、media-kit `73771ec` 的架构，详见 `docs/piliplus-ios-playback.md`；本项目直接调用 libmpv C API，不包含 Flutter。mpv 源码与许可：https://github.com/mpv-player/mpv/tree/v0.39.0 ，FFmpeg：https://ffmpeg.org/legal.html 。
- 应用图标复用本仓库 `assets/brand/logo-pixel.png`。

红果名称及内容相关权利归对应权利人。本客户端与红果官方无隶属或授权关系。
