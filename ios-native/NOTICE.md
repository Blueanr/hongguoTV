# 来源与许可证

本目录代码采用 GPL-3.0-only，许可证全文见仓库根目录 `LICENSE`。

- 内容协议、匿名设备注册、账号端点、媒体索引和解码移植自本仓库 `kotlin-tv/core`；其第三方来源见 `kotlin-tv/NOTICE.md`。
- 签名组件构建时提取 `server/vendor/hongguo.cjs` 的固定算法片段。该文件来源于 drpys，固定版本及原版权信息见 `server/vendor/NOTICE.md` 与 `server/vendor/LICENSE.drpys`。构建脚本仅调整会话 nonce／启动时间，并使用当前 Kotlin 版请求形态。
- 打包依赖 `buffer` 6.0.3：MIT，版权 Feross Aboukhadijeh 及贡献者。其许可证随构建安装的 `node_modules/buffer/LICENSE` 提供，并复制进应用资源。
- `esbuild` 为构建工具（MIT），不作为设备运行时嵌入。
- SwiftUI、AVFoundation、JavaScriptCore、CommonCrypto、Security 和 zlib 使用系统 SDK。
- 应用图标复用本仓库 `assets/brand/logo-pixel.png`。

红果名称及内容相关权利归对应权利人。本客户端与红果官方无隶属或授权关系。
