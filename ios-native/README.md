# 红果 TV · iOS / iPadOS 原生移植

目标设备：**iOS / iPadOS 15.0 及以上的 arm64 iPhone、iPad**。界面使用 SwiftUI，播放使用 AVPlayer；内容请求、请求签名和视频分段处理都在设备本机执行，不需要 Node 服务或 NAS。

## TrollStore 安装

1. 打开 fork 仓库的 **Actions → iOS 15 TrollStore IPA**，选择成功的构建。
2. 下载 `HongguoTV-iOS15-TrollStore` artifact 并解压。
3. 在已安装 TrollStore 的 iPad 上，分享 `HongguoTV-iOS15-TrollStore.ipa` 到 TrollStore 安装。

包名为 `com.hongguotv.ipad`。构建包采用 ad-hoc 签名，供 TrollStore 导入；不需要开发者证书，不是 App Store / TestFlight 安装包。此工程不会安装 TrollStore，本身也不使用私有 entitlement。

## 实现范围

- 推荐片单、真人剧／漫剧／AI 剧分类、搜索、综合热播榜、详情和选集。
- 本机收藏、最近观看、按分集 ID 续播；数据原子写入 Application Support。
- AVPlayer 原生触控控件、横竖屏、全屏、倍速、清晰度切换、定时停止、自动下一集。
- 播放页支持从屏幕左边缘向右滑返回剧集详情，也可点左上角「返回」。选集列表仍可上下滚动；系统播放器独立全屏时先退出系统全屏。
- 播放设置 → 倍速 → 自定义：支持 0.25×～4×、两位小数输入及滑杆调整。速度在本机保存，暂停后继续、切集、切换清晰度与下次打开播放页均沿用。
- 官方网站扫码登录；登录态保存在本机 Keychain。
- 账号收藏读取和添加／取消（写入后回读确认），云端历史、已上线／待上线预约读取。
- 正式播放期间定期上传账号进度；账号片单与本机收藏分开。
- 官网公开剧评／首集评论预览。

**与 Kotlin 主线仍有差异**：尚未移植时间轴弹幕、App 评论分页、多条件筛选、制作方作品、相关季预约和跨季连播；首页使用片单而非电视端首集试播轮播。系统画中画／AirPlay 入口由 AVPlayer 提供，但自定义分段视频的实际支持需要设备验证。Android APK 自更新不适用于 TrollStore，通过安装新 IPA 更新。

最低部署版本和编译成功不等于 iOS 15 实机验收；账号接口、媒体服务和 CDN 的可用性仍受上游影响。

## 当前播放引擎：上游 0.16.14（build 8）

build 11：按用户 M1 iPad Pro 11 英寸第三代的反馈，正式播放器改为原生 libmpv 0.39.0。使用 PiliPlus 同源固定版本框架、speed/audio-pitch-correction、hwdec=auto、display-resample；本机 MediaBytes 通过可取消自定义流接入 mpv，真机 OpenGL ES 渲染、模拟器有界软件渲染。保留自定义倍速、暂停、拖动、清晰度、选集、历史、自动下一集、定时停止；添加全屏按钮与硬解/丢帧/A-V 诊断。系统 AVPlayerViewController 已替换，当前未接入 mpv 画中画，应用转入后台暂停。验收须区分模拟器功能测试和 iPad 真机持续 3× 音画测试。

build 11 模拟器音频限制：固定 v0.39.0 框架的两个 simulator slice 构建配置均为 `-Daudiounit=disabled -Dcoreaudio=disabled`，其他系统 AO 也关闭；设备 slice 为 `-Daudiounit=enabled`。Actions `45382327579` 的音频初始化失败来自模拟器缺失系统输出后端。模拟器改用 mpv PCM 输出并检查实际解码/变速后的非零样本；真机保留正常系统输出。PCM 测试不代表扬声器有声，也不能验证真机 AudioUnit 生命周期。

跨页面／换集时由 `MPVLifetime` 等待旧实例 render context 释放及 `mpv_terminate_destroy` 完成后，再激活新播放器音频会话并创建实例。原因是 mpv 内部 AudioUnit 销毁会停用全局 AVAudioSession，只有 Swift 层 owner 标记不足以隔离这种异步销毁。重复 shutdown 通过完成回调保持幂等。

build 10 音视频重进修复尝试：用户反馈首次 3× 画面卡但有声，重进同集 3× 画面正常却无声。播放器现在等待 readyToPlay、恢复位置并按目标速度 preroll 后启动；退出使旧任务失效，新旧播放器使用音频会话所有者保护，避免迟到的旧页面退出停用新音频会话。音频变速使用 spectral 并仅在创建 item 时设置，切倍速只调整缓冲与 rate。保留 build 9 批量下载和缓存。联网测试增加实际 PlayerModel 的首次 1×→3×、退出重建恢复3×、视频像素帧输出和音轨启用检查；这些检查不能代替 iOS15.0.2 实机扬声器及流畅度验收。

build 10 首轮 Actions `45361717667` 未通过新增验收：首次 3× 仅取到 1/90 帧，重进 86/90 帧；启动后算法读回 TimeDomain。修订版在媒体 ready 和启播后校正算法（仅值变化时设置），进入／离开 >2× 时暂停、原位 seek 和目标速率 preroll 再继续，测试同时检查实际帧和播放时间推进。首轮 IPA 不作为已通过版本交付。

build 10 修订版 `addcf47`：Actions `45366074064` 构建成功，32 项测试全部通过。生产 PlayerModel 首次切 3× 取得 90/90 次新视频帧，退出重建恢复 3× 取得 87/90 次，两轮音轨启用及 Spectral 检查通过；3×、4× 短时推进检查均无等待缓冲采样。上述为模拟器验证，iPad 实机画面和扬声器输出仍需确认。

build 9 高倍速优化：CDN 数据改为持久 URLSession 的批量回调接收，避免逐字节异步循环；按 2 MiB 块缓存最多 4 MiB 解密数据，减少重复 Range 请求和解密；解密索引用二分定位；按倍速设置 8–32 秒前向缓冲并允许 AVPlayer 自动等待缓冲，音频使用低开销时域变速。新增重叠读取／跨块／缓存淘汰验证及 3×、4× 联网时钟推进检查。模拟器测试不能代表老款 iPad 的解码帧率，需要实机复测。

build 9 验证：Actions `45358532611` 构建成功，31 项测试通过。720P 播放／拖动／续播通过；3× 在 3.054 秒推进 9.162 秒，4× 在 3.060 秒推进 12.239 秒，各 30 次采样均未观察到等待缓冲。此为短时模拟器时钟与缓冲验证，并非实机帧率或长期流畅度验收。

已合并 `N3urda/hongguoTV` 最新主线 `ef328f3a3dc28479d90608a507996136672cf946`（2026-11-23，0.16.14），将正式 iOS 播放入口切换为该版本 `MobilePlayback` 协议：

- 本机注册匿名设备，沿用上游 `log5-applog-lf.fqnovel.com` 注册流程。
- `reading.snssdk.com/novel/player/multi_video_model/preload/v1`，应用参数 `7.4.5.32`、`device_level=2`、`dr_scene=preload`。
- v5 Medusa 字段 21 更新为 `312`，与上游独立合成向量逐字节对照。
- 没有兼容资源时使用模型提供的 `fallback_api`，按 `codec_type=1`、`3` 协商 H.264/HEVC；保留精确分集匹配和有界空响应回退。
- 请求在 iPad 本机签名并通过有大小限制、支持取消的 URLSessionDataTask 传输。当前播放路径不需要 SDI 初始化资料下载。

2026-11-24 验证：本地签名验证通过；Actions `45354549153` 原生 IPA 构建成功，29 项 Swift 测试全部通过。最新上游接口第 1、54、71 集分别取得 5、5、1 条兼容资源，均通过 CDN MP4 Range 检查；默认 720P AVPlayer 播放、拖动及续播测试通过。iOS 15.0.2 实机仍需覆盖安装确认。

## 历史：Drama SDI 会话（build 5–7）

build 7：针对 iOS 15.0.2 实机在“匿名设备注册”阶段报 URL -1000，注册、会话和模型 POST 改用传统 URLSessionDataTask 委托传输，避开 AsyncBytes POST 路径；保持原始签名地址、请求头和请求体，保留取消、响应大小限制和禁止重定向。此为兼容性修复尝试，尚需该实机确认，不能仅凭新系统模拟器通过认定根因。

参考 [jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama) 提交 `bc02370ff519adf7a94a20688c5538ac303f4ec7` 的 `scripts/sdk-playback` 重构：本机匿名注册 → `/sdi/get_token` 初始化（最多两次，202 → 200）→ 携带 token 的 v5 播放签名 → 精确分集模型 → 现有 AVPlayer/CENC 播放器。

原桌面辅助程序使用 Python/Unicorn；本移植在 JavaScriptCore 中执行可移植算法，Swift 提供密码算法、压缩与网络，不依赖电脑或 NAS。摘要固定选择经原始 SDK 对照的分支 12，只在最终 query 的 `_rticket` 上进行有界搜索。会话包含 token、动态 Ladon、Gorgon、完整设备描述和注册 Cookie。设备资料保存在不参与备份的 Application Support/drama-playback；会话 token 只保留在内存。初始化串行化，切集可取消，失败后冷却 10 秒，下一次手动请求才重新初始化。

首次使用从参考项目固定的官方 APK 地址分段下载约 5.4 MB SDK 初始化资料，校验压缩块和提取内容的 SHA-256 后缓存。只读取配置与协议表，不执行 Android `.so`。首次取源需要额外下载时间。

2026-11-23 验证：参考 Python 实现与移植 JS 均完成 202 → 200 会话；移植 JS 第 1 集、第 54 集、末集均取得精确分集模型。独立 Python 合成向量验证 SDI 加密、响应解码与 Gorgon 通过。Actions `45187157851` 真机 IPA 构建成功，23 项 Swift 测试全部通过（含实际联网测试）：第 1、54、71 集各取得 5 条资源，并通过 CDN HTTP 206 / MP4 `ftyp` Range 检查。iPad 实机 AVPlayer 解码、声音与拖动仍需安装验收。

## 历史：openhongguo 0.4.0（build 4）

播放入口已替换为 [openhongguo](https://github.com/beilunyang/openhongguo) 原生 Swift SDK，固定版本 **0.4.0**。SDK 在本机处理匿名设备注册、持久化、签名、播放模型与内容密钥。设备被拒或播放空响应时，一次调用最多更换 2 台匿名设备，可重试网络请求最多尝试 3 次；应用设置 60 秒总等待上限，退出或切集会取消 SDK 请求。

返回的兼容 MP4 资源接入现有 AVPlayer/CENC 播放器，保留侧滑返回、自定义倍速、清晰度和续播。SDK 的匿名资料保存在 Application Support/openhongguo/anonymous.json，不参与系统备份。片单、账号功能使用已有入口。SDK 返回仍受上游可用性影响，空响应重试耗尽时会明确显示错误。

2026-11-23 Windows Node SDK 0.4.0 对照：搜索与分集列表成功，播放在 SDK 有限恢复后返回 `ANONYMOUS_LIMITED`。此结果不等同于 iOS 原生 SDK 或 iPad 实机验收。

## 历史：0.16.13 播放接口同步（build 3）

播放链已对齐 Kotlin `kotlin-v0.16.13`（`ac3a1e2e866b2a917651575ba507adfe62344932`），详情见 [接口核对记录](PROTOCOL_ALIGNMENT.md)。此前 iOS 版保留 0.16.2 的单集 Argus/Ladon 与 v3 批量回退；新版使用 v5 Medusa/Helios/Khronos、gzip 请求体与 `/novel/player/multi_video_model/player/v1`。

主接口空响应后，同一匿名设备使用 v5 签名的 video-tab GET；若仅返回不支持的 bytevc2，则按 0.16.13 在备用域名重试新版 POST。GET 签名使用空字节摘要，线上不发送请求体、POST 专用头或账户 Cookie。明确拒绝、格式异常、服务退避不会触发盲目回退。网站片单与已有账号功能仍使用各自协议。

## 构建

GitHub Actions 使用 macOS runner，完成真机 Release 构建、ad-hoc 签名检查、iPad 模拟器测试后上传 IPA。触发方式：推送 `ios-native` 分支或手动运行工作流。

本地需要 macOS、Xcode、Node 22、Python 3、XcodeGen 和 Pillow：

```sh
brew install xcodegen
python3 -m venv .venv
.venv/bin/pip install Pillow==11.3.0
export PATH="$PWD/.venv/bin:$PATH"
bash scripts/build-ios.sh
```

输出：`outputs/ios/HongguoTV-iOS15-TrollStore.ipa` 和 `SHA256SUMS.txt`。

`project.yml` 是 Xcode 工程唯一来源；`HongguoPad.xcodeproj`、图标槽位与签名 JS bundle 在构建时生成。旧 `ios/` 是历史 React Native tvOS 工程，本构建入口为 `ios-native/`。

## 测试与结构

- `Sources/Repository.swift`：网站片单、匿名设备注册、播放模型。
- `Sources/SDKPlayback.swift`：当前 openhongguo 播放入口、资源/密钥适配与错误提示。
- `Sources/MobilePlayback.swift`：保留的 0.16.13 v5 协议回归参考，当前播放不调用该路径。
- `Sources/Signer.swift` 与 `tooling/`：JavaScriptCore 执行仓库中已固定来源的签名算术；不执行网络下发脚本。标准哈希调用 CommonCrypto，SM3 有标准向量覆盖。
- `Sources/MediaResource.swift`：有界 Range 读取、MP4 索引校验、CENC 子样本 CTR 解码、AVAssetResourceLoader。
- `Sources/Account.swift`：扫码流程、Keychain、账户读写。
- `Tests/CoreTests.swift`：路由字符串解析、SM3、AES-CTR、异常 MP4、播放资源过滤及签名集成测试。

```sh
npm --prefix ios-native/tooling ci
npm --prefix ios-native/tooling run build
npm --prefix ios-native/tooling test
```

可选联网诊断：`node ios-native/tooling/probe.mjs`。它检查片单、详情、匿名注册、新版 v5 主接口及必要的备用播放模型，抽查首集／第 54 集（不足则最后一集）／最后一集的 CDN MP4 分段，只输出阶段和数量。该结果不是 iPad 实机播放验收。

协议实现来源于本仓库 `kotlin-tv/core`，签名算术构建时复用 `server/vendor/hongguo.cjs` 中固定来源的算法片段；版权与许可证见 [NOTICE](NOTICE.md)。
