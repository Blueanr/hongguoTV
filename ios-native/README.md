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
- `Sources/Signer.swift` 与 `tooling/`：JavaScriptCore 执行仓库中已固定来源的签名算术；不执行网络下发脚本。标准哈希调用 CommonCrypto，SM3 有标准向量覆盖。
- `Sources/MediaResource.swift`：有界 Range 读取、MP4 索引校验、CENC 子样本 CTR 解码、AVAssetResourceLoader。
- `Sources/Account.swift`：扫码流程、Keychain、账户读写。
- `Tests/CoreTests.swift`：路由字符串解析、SM3、AES-CTR、异常 MP4、播放资源过滤及签名集成测试。

```sh
npm --prefix ios-native/tooling ci
npm --prefix ios-native/tooling run build
npm --prefix ios-native/tooling test
```

可选联网诊断：`node ios-native/tooling/probe.mjs`。它检查片单、详情、匿名注册、单集及备用播放模型和 CDN MP4 分段，只输出阶段和数量。2026-11-14 本地采样曾出现单集空响应，后续复测成功取得 5 档资源；该结果不是 iPad 实机播放验收。

协议实现来源于本仓库 `kotlin-tv/core`，签名算术构建时复用 `server/vendor/hongguo.cjs` 中固定来源的算法片段；版权与许可证见 [NOTICE](NOTICE.md)。
