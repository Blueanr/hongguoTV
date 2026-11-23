# 0.16.13 APK / iOS 播放接口核对

## 参考身份（2026-11-23）

- 用户提供 `hongguotv-kotlin-0.16.13-android6-arm64-v8a.apk`。
- 本机 SHA-256：`9d95782a2a34f913c887f68413472f0aabe85d0c86c49e18d19a3ce0ca42f544`。
- GitHub Release `N3urda/hongguoTV` / `kotlin-v0.16.13` 对应同名 asset 的 API digest 与上述哈希完全一致，发布目标为 `ac3a1e2e866b2a917651575ba507adfe62344932`。
- 通过本机 Python ZIP/DEX 字符串解析，`classes.dex` 中观察到新版 POST 路径（偏移 2075167）、video-tab 路径（2075944）、`7.4.3.32`（2080566）、`v04.10.03-ml-android`（2340974）及新版 biz_param（2344106）。复现：`python scripts/inspect-android-reference.py`，报告写到 `outputs/ios/android-reference.json`。
- REA Android 反编译因未配置 `REA_JADX_MCP_JAR` 不可用；上述证据来自本机哈希、ZIP/DEX 静态字符串与 GitHub 发布元数据，不是 REA 反编译或 APK 运行记录。完整调用顺序根据匹配发布版本的 Kotlin 源码建立。

## 根因与修复

| 项目 | 原 iOS 版 | 本次对齐 |
|---|---|---|
| 主请求 | `/novel/player/video_model/v1/`，单集 Argus/Ladon | `sinfonlinea` 域名 `/novel/player/multi_video_model/player/v1`，v5 |
| 版本资料 | 7.3.5.32 / 7.3.9.32 | 播放参数 7.4.3.32、vivo_8662_64、PGT-AN10、Android 12 |
| 主请求体 | 未压缩单集 JSON | gzip JSON，mixed_video_id_map.1004，dr_scene=player，device_level=1 |
| 签名 | 旧版 v3 / Argus | v04.10.03 Medusa、Helios、Khronos；对最终 query 与实际 gzip 字节签名 |
| GET 回退 | v3、可携带注册 Cookie | 同一设备 v5，MD5(empty)，不发送 Cookie、body、Content-Type、Content-Encoding、x-ss-stub |
| 无兼容编码 | 旧版批量 POST | video-tab 仅 bytevc2 时，在 sinfonlineb 请求新版 POST |
| 响应选择 | 旧版 video_model_data / data | 新版 data.1004 / data；GET data.video_model_data / data；必须匹配请求分集 ID |
| 画质 | 仅元数据尺寸 | 同时读取顶层尺寸及 video_list 字典画质名 |

参考实现：该提交下 `MobilePlayback.kt`、`ContentRepository.streamLadderWithCompatibility`、`Signer.kt`、`AesV3.kt`、`V5Constants.kt` 与 `SIGNING_V5.md`。签名算术仅移植 GPL 实现，测试向量为上游合成输入；不嵌入 SDK、远程签名服务或抓取的用户会话。

## 验证边界

Swift 回归测试覆盖主请求 gzip 与摘要、v5 GET 头部、同设备同集回退、bytevc2→备用 POST、错误分集/格式/退避停止与取消行为。JS 使用上游独立签名向量校验。联网探针使用新匿名设备，抽查首集与后续集的模型及 MP4 Range。

GitHub Actions 手动运行时可勾选 `live_playback`，通过 `TEST_RUNNER_HONGGUO_LIVE_PLAYBACK=1` 在 iPad 模拟器调用实际 Swift `Repository.streams`，验证模型、签名及 CDN Range。常规构建跳过该联网项，避免把上游可用性当作单元测试；其余回归测试正常运行。

本次同步是播放接口修复，不代表 iOS 与 Android 全功能等价；完整功能差异见 README。播放 UI、AVPlayer 解码、iPad 手势仍需要实机验收。

### 已执行结果（2026-11-23）

- JS：32 组独立 F13、4 组 carrier、8 组完整 Kotlin 签名与 64 组 GET/POST 轮换检查通过。
- Actions `45175510100`：真机 IPA 编译成功，16 项离线 Swift 回归测试通过；显式联网测试失败，主接口及 video-tab 恢复未取得非空模型。该运行整体标记失败，不能作为播放恢复的证明。
- Windows Node 探针：首轮片单、详情（71 集）、匿名注册成功，但两个模型请求均为空；随后检查中网站片单 HTTP 502。探针已修正数字设备 ID 超过 JS 安全整数范围时的解析风险，Swift 使用 Foundation NSNumber 不受该探针问题影响。
