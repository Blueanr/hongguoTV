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

## 交付门槛

真实取源与解密播放测试通过后再下载、校验交付 IPA。M1 iPad Pro 11 英寸第三代仍需确认首次和重进 3× 的声音、硬解及持续流畅度。当前不支持画中画，后台暂停。
