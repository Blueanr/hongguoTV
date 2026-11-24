# build 11 验收记录

## 已验证：离线原生 libmpv 回归

- 提交：`d4d26df`；Actions：`45396071806` attempt 1。
- 设备 IPA 编译成功；36 项模拟器测试中 35 项通过。
- `testOfflineMPVReentryWithGeneratedAudioVideo` 通过：本地生成的 H.264/AAC faststart MP4 经内存 Range、`MediaBytes`、mpv 自定义流和正式 `PlayerModel` 播放。
- 首次 3× 观察到 146 次渲染更新，PCM 786432 字节；重进 3× 观察到 107 次渲染更新，PCM 299008 字节。两次均有非零音频样本、`audioOutput=pcm`、`pitchCorrection=true`。
- 暂停后改 4× 保持暂停、seek 后 4× 续播、速度恢复，以及自定义流取消和销毁／音频会话隔离测试通过。

渲染更新可能包含重复帧，不等于独立解码帧。模拟器 `hwdec=no`，软件渲染且使用 PCM 输出；日志的累计丢帧为 146／155，不能据此证明真机 3× 流畅。PCM 非零样本也不等于扬声器验收或音高校正效果的听感验收。

## 未通过：真实取源

同轮 `testProductionUpstreamPlaybackModels` 在推荐列表首部剧的首集取源时，连续 3 次返回空响应；没有进入该真实视频的 mpv 播放。源请求使用上游 0.16.14 的 preload 和 video-tab 回退。

后续添加 DEBUG 构建的接口方法／主机、HTTP 状态、字节数及耗时记录；当 3 次空响应耗尽时，额外探测另外两部推荐剧用于定位。探测结果不会把失败的联网测试改成通过。

## 空响应范围对照

- `e4d5ac5` / Actions `45398879027`：三部推荐剧的主 POST 与备用 GET 均返回 HTTP 200、0 字节；离线内核回归再次通过（首次／重进 173／180 次渲染更新）。全套 36 项中 35 项通过。
- 本机 Node 探针更新为当前 7.4.5.32 preload 参数后，一次运行完成三集对照：主 POST 均 0 字节，备用 GET 分别 20941／22274／21690 字节，解析出 5／5／1 档兼容资源，三集 CDN MP4 Range 通过。
- 这不能单独区分云端出口、运行时请求差异和匿名注册会话差异。下一轮 CI 在同 runner 执行 Node 取源探针，再运行必过的 Swift 全链路测试；探针失败只记录，不跳过 Swift 测试。Node 探针使用独立的一次匿名注册，不等于与 Swift 复用了同一会话，也不验证 iOS 解密／渲染。

## 云端完整验收通过

- 提交 `c772076`；Actions `45401379877` attempt 1：**success**，36 项测试零失败。
- 同 runner 的 Node 对照与 Swift 真实取源均通过。Swift 首集、索引 53 和末集索引 70 均在第 1 次尝试成功，CDN MP4 Range 通过，分别 5／5／1 档资源。
- 真实视频经 `MediaBytes` 与正式 mpv 播放：首次 3× 169 次渲染更新、774144 字节非零 PCM；重进 3× 179 次渲染更新、581632 字节非零 PCM。两次 `hwdec=videotoolbox-copy`、`speed=3`、`pitchCorrection=true`、`audioOutput=pcm`；累计丢帧 59／48。暂停改 4× 保持暂停、seek 及 4× 续播断言通过。
- 离线测试同轮通过，首次／重进 168／179 次渲染更新；销毁、取消等其他回归也通过。
- 构建设备 IPA 的 macOS 脚本完成各框架 ad-hoc 签名，以及应用 `codesign --verify --deep --strict` 检查。
- 前几轮空响应的根因仍未证实；本次未修改正式取源实现，两种运行时都成功，不能把增加诊断当成修复上游故障。

## 包校验与实机验收

真实取源与解密播放测试已通过；下载后再校验 ZIP、版本、最低系统、19 个 mpv 依赖框架及 SHA256。M1 iPad Pro 11 英寸第三代仍需确认首次和重进 3× 的声音、硬解及持续流畅度。模拟器的 videotoolbox-copy 和 PCM 结果不代表 iPad 的设备输出验收。当前不支持画中画，后台暂停。

本地下载校验已完成：

- 路径：`outputs/ios/build-11/HongguoTV-iOS15-TrollStore.ipa`，11234973 字节。
- SHA256：`628e4880c938dc56bcf52437d8e8baed1f7d04b9d47bdd5120ce4b1212580bcb`，与云端 `SHA256SUMS.txt` 一致。
- ZIP CRC 全部通过；plist 为 `0.16.14` / build `11` / 最低 `15.0`，bundle ID `com.hongguotv.ipad`。
- 内嵌 19 个 mpv 依赖框架，加原有 `OpenhongguoCore.framework`，共 20 个框架；设备 arm64 可执行文件及代码签名 blob 存在。完整签名验证由上述 macOS 构建完成。
- 本地详细校验输出：`outputs/ios/build-11/verification.json`。
