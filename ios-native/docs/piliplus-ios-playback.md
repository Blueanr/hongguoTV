# PiliPlus iOS 倍速实现核对

## 核对版本

- PiliPlus：`217fb54f51f6764176319bbdedab2a7522d75401`。
- `pubspec.lock` 锁定的 My-Responsitories/media-kit：`73771ec38176be2d984a3049c28177bce23b54a0`，与本次拉取的 native 分支一致。
- iOS libmpv 包：Makefile 指向 gungun974/melodink-libmpv-darwin-build 的 `v0.39.0`，带下载 SHA-256 校验。

## 源码结论

1. iOS 正式播放使用 media_kit → libmpv，不使用 AVPlayer。
   - PiliPlus `lib/plugin/pl_player/controller.dart:843–875` 创建 Player 和 VideoController。
   - media-kit `media_kit_video/lib/src/video_controller/native_video_controller/real.dart:76–88` 设置 `vo=libmpv`、`hwdec` 和 `vid=auto`。
2. 倍速是设置 mpv 的 `speed` 属性。
   - PiliPlus `controller.dart:1198–1204` 调用 `setRate(speed)`。
   - media-kit `media_kit/lib/src/player/native/player/real.dart:654–680`，默认分支执行 `_setPropertyDouble('speed', rate)`。
   - `PlayerConfiguration.pitch` 默认 false，PiliPlus 没有打开该选项。不要把另一分支的手动 `scaletempo:scale=...` 当成 PiliPlus 默认路径；pitch=false 表示未启用独立音调控制，并非关闭音高校正。
   - mpv v0.39.0 文档说明 `audio-pitch-correction` 默认启用，倍速会自动插入 `scaletempo2`。这不是 AVFoundation 的 Spectral/TimeDomain 设置。
3. 默认允许硬解，iOS 的 `hwdec` 默认值是 `auto`，不是显式固定 `videotoolbox`。
   - `lib/utils/storage_pref.dart:266–272,803–804`。
   - `lib/plugin/pl_player/models/hwdec_type.dart:45–49`。
   - VideoToolbox 是提供的 Apple 平台硬解选项；实际是否选中必须查看运行时 `hwdec-current`，不能把 auto 配置当成硬解成功的证据。
4. 默认 `video-sync=display-resample`，在 Player 创建时传入。
   - `storage_pref.dart:271–272` 和 `controller.dart:845–858`。
5. 点播缓冲时间乘以初始倍速，并设置 demuxer 字节上限。
   - `storage_pref.dart:857–866`：`cache-secs=bufferSec*playbackSpeed`，同时设置 `demuxer-hysteresis-secs`、前后向缓存字节数。
   - `controller.dart:890,921–927`。这里是延迟初始化的 buffer 配置，不能声称每次切倍速都动态扩大缓存。
6. iOS 使用独立纹理渲染链路。`ios/Runner/PipPlugin.swift:6–12` 表明画中画也是把 mpv 像素帧送到 AVSampleBufferDisplayLayer，而非切回 AVPlayer。
   - media-kit `common/darwin/Classes/plugin/VideoOutput.swift:76–114` 明确区分真机硬件渲染与模拟器软件渲染，所以模拟器不能代替真机性能验收。

## 对当前红果 iOS 的判断

build 10 真机 3× 仍卡，说明此前 ready/seek/preroll、音频算法和缓冲调整没有解决用户问题。模拟器帧输出通过不代表 iOS 15 iPad 解码和显示流畅。

Apple QA1772 明确说明：超过 2×、数据率或处理要求超出能力时，AVPlayer 会降低播放质量，其中一种策略是只解码显示 I 帧；`canPlayFastForward=true` 不保证平滑。这与反馈相符，但目前没有真机解码、网络和帧时间数据，不能认定它是唯一根因。AVPlayer 本身也可能使用硬件解码，差异不等于“AVPlayer 软解、mpv 硬解”。

## 可落地的移植方向

应评估在现有 SwiftUI 应用内接入原生 libmpv，复用接口、签名和 CENC 解密，而非仅照抄倍速参数：

- 封装 mpv 生命周期、事件、speed/pause/seek、音轨和错误；保留 0.25×～4×、速度持久化及暂停后恢复。
- 替换 AVPlayerViewController 的视频呈现和控制接口，接入 libmpv render API；明确 iOS 15、arm64、模拟器 slice、链接依赖和签名支持。
- `MediaBytes` 可复用，但当前 `hongguo-media://` 通过 AVAssetResourceLoader 供给数据，mpv 不能直接使用它。需要可取消、可 seek 的 mpv 自定义流桥接，将异步 Range 下载/解密接到解复用读取线程；也可设计仅设备本机的 Range 服务。无需电脑或 NAS。
- 用 `hwdec-current`、解码/显示丢帧、音画偏差、缓存状态和实际输出帧间隔区分瓶颈。硬解选择和音高校正必须有运行时结果。
- 使用同一分集、清晰度和编码，对照首次 1×→3×、直接恢复 3×、退出重进、暂停续播、拖动、换集；实机持续播放及扬声器输出必须验收。

本次为源码调研，没有切换播放内核，没有生成新 IPA，也不能承诺换内核即可让所有旧 iPad 的 3× 流畅。

## 参考

- https://github.com/bggRGjQaUbCoE/PiliPlus/blob/217fb54f51f6764176319bbdedab2a7522d75401/lib/plugin/pl_player/controller.dart
- https://github.com/bggRGjQaUbCoE/PiliPlus/blob/217fb54f51f6764176319bbdedab2a7522d75401/lib/utils/storage_pref.dart
- https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/media_kit/lib/src/player/native/player/real.dart
- https://github.com/My-Responsitories/media-kit/blob/73771ec38176be2d984a3049c28177bce23b54a0/libs/ios/media_kit_libs_ios_video/ios/Makefile
- https://github.com/mpv-player/mpv/blob/v0.39.0/DOCS/man/options.rst
- https://developer.apple.com/library/archive/qa/qa1772/_index.html
