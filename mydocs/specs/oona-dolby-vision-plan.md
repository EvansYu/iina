# oona 杜比视界播放与安装包技术方案

日期：2026-10-13。分支：`oona`。状态：方案待审阅；本轮未实现、未构建应用、未打包。

## 目标与完成条件

1. 用户当前泛绿的视频能在 oona 中以正确颜色播放，并保持音画同步、字幕、拖动进度等基本体验。
2. 第一版验收建议覆盖 HEVC Dolby Vision Profile 5、8.1、8.4；HDR/EDR 显示器保留高光，SDR 显示器正确色调映射。
3. 交付可拖入 Applications 的 `oona.app` 和 `oona-<version>-macOS-arm64.dmg`、SHA-256、构建依赖清单及测试报告。应用与 IINA 可并存。
4. 具体问题片源、目标显示器尚未提供，第一项目前没有复现证据。不能以编译成功或单张截图作为杜比视界支持完成的依据。

本轮仅做调研和计划，符合用户“先制定方案”的要求。后续实现须在用户接受范围后进行；不发布、不修改其他工作仓库。

## 已核实的代码与环境

| 事实 | 证据 |
| --- | --- |
| IINA 固定使用 vo=libmpv，Render API 为传统 OpenGL | [MPVController.swift](../../iina/MPVController.swift)，约 659–690 行 |
| HDR 识别依赖 gamma 与 primaries，输出依赖 PQ 色彩空间、EDR 与 tone mapping | [VideoView.swift](../../iina/VideoView.swift)，refreshEdrMode、isHDRVideo、requestEdrMode |
| 实际绘制层为 ViewLayer，使用 CAOpenGLLayer/FBO，有 RGBA16Float 配置 | [ViewLayer.swift](../../iina/ViewLayer.swift)，draw、像素格式选择 |
| 播放状态与 HDR 刷新由 PlayerCore 协调 | [PlayerCore.swift](../../iina/PlayerCore.swift)，refreshEdrMode |
| Inspector 当前主要显示 primaries/gamma/sig-peak | [InspectorWindowController.swift](../../iina/InspectorWindowController.swift) |
| 项目引用 libmpv.2、libplacebo.360、libavcodec.63；库名不证明实际 DV 支持 | [project.pbxproj](../../iina.xcodeproj/project.pbxproj) |
| 下载脚本使用在线 filelist，不能作为可复现版本锁定 | [download_libs.sh](../../other/download_libs.sh) |
| 应用名 IINA、bundle ID com.colliderli.iina；entitlements 路径含 PRODUCT_NAME | [iina.xcconfig](../../Configs/iina.xcconfig) |
| CLI 硬编码启动同目录 IINA；Safari 扩展使用 iina URL scheme | [CLI](../../iina-cli/main.swift)、[SafariExtensionHandler.swift](../../OpenInIINA/SafariExtensionHandler.swift) |
| App Support 目录基于 bundleIdentifier；官方更新源在 plist 与 Swift 中 | [Utility.swift](../../iina/Utility.swift)、[AppDelegate.swift](../../iina/AppDelegate.swift)、[Info.plist](../../iina/Info.plist) |

本机：arm64、macOS 26.3；完整 Xcode 26.6 已安装，可通过 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 使用，无须更改全局 xcode-select。初始化时仅检查默认选择目录而得出的“不能构建”结论在本次得到修正。仓库 CI 配置 Xcode 27，26.6 能否构建当前源码仍须验证。
本机独立 mpv 为 0.41.0，libplacebo 7.360.1，FFmpeg/ffprobe 9.0.2；这些不是本项目最终发行依赖的已确认版本。

## 原因判断与支持边界

高概率原因是 DV 色彩表示/reshaping 元数据未被当前渲染路径正确处理，尤其是没有 HDR10 兼容基层的 Profile 5。尚未读取用户视频，因此仍需排除错误封装、硬解帧元数据丢失、用户滤镜和色彩覆盖配置。
Dolby 官方说明 Profile 5 的专有表示和 Profile 8 的 HDR10/HLG 兼容类别；libplacebo 明确支持 DV 元数据处理、reshaping 和 Profile 5 转 HDR/PQ 或 SDR。[S1][S2]

| 类型 | 第一版拟定行为 | 边界 |
| --- | --- | --- |
| Profile 5 | 处理 DV 元数据并正确转换颜色；HDR 与 SDR 分别输出 | 不允许把专有基层当普通 HDR10 显示；禁用元数据不能充当修复 |
| Profile 8.1 | 验证 DV 路径；必要时可显式回退 HDR10 兼容基层 | 记录实际启用模式，回退不标成完整 DV |
| Profile 8.4 | 验证 DV/HLG 路径、显示器输出及动态切换 | 不能直接套用 8.1 的 PQ 基层假设 |
| Profile 7 MEL/FEL | 识别并验证可用路径；最低可采用确认兼容的 HDR10 基层 | 第一版不承诺完整双层/FEL 重建；需要独立样本、解码与渲染联合验证 |
| SDR、HDR10、HLG | 保持正常播放，作为回归矩阵 | 不应被 DV 专用配置污染 |

上述为推荐验收范围，需结合问题片源确认。现代 libplacebo 源码已有 FEL enhancement_layer 接口，不能笼统声称上游永远不支持；这也不证明指定 mpv/FFmpeg/libplacebo 组合已经贯通 FEL。[S6]
输出目标是 Mac 上正确的图像和 HDR/SDR 呈现，不承诺 HDMI 原生 Dolby Vision 元数据透传、电视点亮 DV 标志或 Dolby 认证。

## 推荐架构与方案选择

保持 IINA 的播放控制、窗口、字幕和音频体系，构建配套的 libmpv + FFmpeg + libplacebo，补齐嵌入式 gpu-next 渲染能力，优先复用现有 OpenGL/FBO 显示层。

拟定链路：

```text
媒体文件
  -> FFmpeg 解封装与解码（保留 DV 配置和逐帧 RPU 元数据）
  -> libmpv 嵌入式 gpu-next / libplacebo
  -> DV reshaping、色彩转换、显示映射
  -> IINA ViewLayer FBO
  -> VideoView 配置的 macOS EDR/PQ 或 SDR/ICC 输出
```

这张链路是目标设计，不表示当前项目已经具备 gpu-next。

### 关键依赖决策

截至本次查询，mpv PR #16818 仍是 Draft，且已从 0.42 里程碑移除；不能依赖某个正式版本一定包含接口。[S3]
IINA 作者的实验提交 `97179bce7ed980c53647d6344916f632fe689e9e` 增加 `MPV_RENDER_API_TYPE_OPENGL_NEXT`，复用 OpenGL 初始化/FBO 参数，是第一优先验证候选。它仍是实验代码，OpenGL 路径、硬解互操作及帧生命周期须本机验证；不能直接视为发布依赖。[S4]
旧 PR 使用 `MPV_RENDER_PARAM_BACKEND`，与上述方案 ABI 不同，不可混用头文件和 dylib，也不可在 Swift 中硬编码未知枚举值。若新候选不可用，再评估旧实现中可审计的最小补丁；记录结论后更新本方案，不在实现中静默转为另一整套架构。

| 方案 | 判断 |
| --- | --- |
| 配套 libmpv + libplacebo，嵌入式 OpenGL gpu-next | 推荐先做最小验证；保留现有 UI，主要风险集中在底层接口、硬解互操作和色彩输出 |
| 仅切换 vo=gpu-next 或升级现有 dylib | 无法证明接通 Render API，不作为实施方案 |
| 手调色相、固定 LUT 或统一剥离 DV 元数据 | 不能正确处理逐帧 DV 转换，不作为正式修复 |
| 重写 Metal 渲染层或另接 AVFoundation 播放引擎 | 变更范围扩大到帧调度、字幕、滤镜和窗口集成，作为后续架构选项，第一版不直接采用 |

## 检查点与代码修改计划

### P0：复现与可行性验证

- 获取问题视频路径，用 ffprobe 输出 profile、兼容 ID、BL/EL/RPU 标志、位深、色彩标签和容器；不以文件名识别 DV。
- 记录默认 IINA、干净配置下独立 mpv gpu-next 的同片表现，并分别验证软解与 VideoToolbox 路径。独立 mpv 仅作为对照，不作为 oona 播放入口。
- 用完整 Xcode 建立当前 IINA 基线；锁定媒体库源码提交和构建参数。
- 建立最小 libmpv OpenGL-next 验证程序，实测 macOS GL 上下文、FBO、DV 元数据、硬解/拷贝解码、截图、resize、seek 和销毁。
- 通过标准：P5 实际样本颜色正常且元数据链路可追踪，FBO 输出/刷新/退出稳定。失败时明确失败层次和下一条可行路径，不进入“已支持 DV”的打包交付。

### P1：可复现媒体依赖

拟新增 `other/oona/build-media-deps.sh`、`media-deps.lock.json`、`patches/`、`verify-media-deps.sh`。
记录 mpv/FFmpeg/libplacebo 源码提交、补丁哈希、架构、部署目标、编译选项和库清单；在本仓库构建目录中下载构建，不修改其他仓库。
同步完整配套头文件和 dylib 到 `deps/`，按实际 SONAME 更新 Xcode Frameworks/Copy Dylibs。检查 `otool -L`、rpath 和依赖闭包；不以软链接假冒不同 FFmpeg ABI。包内不依赖 Homebrew 绝对路径。若更新 mpv 生成常量，使用现有生成脚本而非手工修改生成文件。

### P2：嵌入式渲染、状态与色彩管理

| 文件 | 修改内容 |
| --- | --- |
| `iina/MPVController.swift` | 使用锁定头文件的 OpenGL-next API；记录实际后端、初始化错误和能力；接入必要的元数据/色彩属性变化；保留同步和回调规则 |
| `iina/ViewLayer.swift` | 核实 FBO 内部格式/位深、浮点输出、翻转、ICC 传递、上下文状态和销毁；替换旧后端不兼容假设 |
| `iina/VideoView.swift` | 区分源 DV 表示和显示目标，校准 EDR/PQ、SDR tone mapping/ICC；避免重复色调映射；覆盖拖动到另一屏幕及 HDR 开关 |
| `iina/PlayerCore.swift`、`PlaybackInfo.swift` | 统一维护检测与实际输出状态；文件切换/结束时清空；控制有限次数的回退与重试 |
| 新增 `iina/VideoColorPolicy.swift`（如有必要） | 承载可测试的模式决策，避免色彩判断散落；不重新实现 DV 数学算法 |
| `iina/InspectorWindowController.swift`、Base/en 字符串 | 展示 DV 已处理、HDR/SDR 输出或兼容基层状态；不因文件带 DV 标签就报告成功 |

运行时信息以锁定版本实际提供的 mpv 属性为准。其 `video-out-params` 是滤镜后的源参数，不等于显示目标；目标按实际渲染设置及可用的 `video-target-params` 核对。[S5]
若 mpv 不提供 profile/RPU 必要信息，在底层适配中提供最小只读诊断，不让 GUI 每帧启动 ffprobe。ffprobe 用于测试采样和复现报告。

解码优先验证 VideoToolbox；发生兼容问题时允许有限尝试 videotoolbox-copy/软解，并恢复用户原始选项。复制和软解的元数据保真与 4K 性能需要分别验收。普通内容可保留传统渲染回退；P5 不可静默回退到已知会泛绿的路径。
后端通常在打开文件前创建，因此第一版优先在 core 生命周期内选择新后端，不做无同步保护的逐帧切换。状态回退若需要重建 core，应明确保留位置、音轨和字幕选择并防止重试循环。

### P3：oona 名称与身份隔离

- `Configs/iina.xcconfig`：产品和显示名设为 `oona`；使用独立 bundle ID（暂拟 `local.oona.player`，正式签名时固定为所属团队可用标识）。保留内部 target/Swift 模块名以限制无关重命名。
- 同时固定 `CODE_SIGN_ENTITLEMENTS` 指向实际 `iina/iina.entitlements`，避免 PRODUCT_NAME 改名导致构建引用不存在的文件。
- `iina/Info.plist`：使用 `oona://`，更新服务/显示名称与文件关联身份；不抢占 IINA 的 URL scheme。
- `OpenInIINA` 的 xcconfig、plist、handler：子 bundle ID 与主应用匹配，打开 oona 协议，保持扩展能正确启动新应用。
- `iina-cli/main.swift` 和相关打包项：交付 `oona-cli`，修正硬编码可执行路径；同步检查插件 CLI。
- `AppDelegate.swift`、`AppData.swift`、`Info.plist`、菜单/关于窗口相关资源：禁用 IINA 官方 Sparkle 更新检查及入口，避免安装包被官方 IINA 替换；不把空 feed 当作唯一禁用手段。
- 检查偏好、App Support、缓存、日志、历史和插件目录；现有 Utility 基于 bundle ID，可利用其自然隔离。默认不迁移或覆盖 IINA 数据。
- 产品名使用资源/品牌常量或针对性构建处理；不全仓替换 `IINA`，不修改原作者版权和许可证，不批量重写 Crowdin 翻译。

### P4：测试、签名与 DMG

拟新增 `other/oona/build-app.sh`、`package-dmg.sh`、`verify-bundle.sh`，交付目录使用已被忽略的 `build/oona/`。
先提供本机 arm64 包。Universal 只有在 arm64/x86_64 依赖齐全且分别通过验证后交付，不把本机验证当作 Intel 兼容证据。
Release 构建后检查主应用、扩展及嵌套动态库签名与依赖；创建含 Applications 快捷入口的 DMG，挂载、复制到测试目录并运行确认。
有可用 Developer ID 和公证凭据时进行正式签名、公证及 stapling；否则提供明确标注的本地 ad-hoc 测试包，说明其 Gatekeeper 限制，不宣称“免警告分发”。不修改系统安全设置。
安装包附上版本、构建提交、依赖锁定信息、SHA-256、许可与测试结论。

## 验收矩阵

| 维度 | 用例与证据 |
| --- | --- |
| 颜色 | 用户问题片源、P5/P8.1/P8.4，灰阶/肤色/高饱和/高光；同一 tone-mapping 目标下与可信参考逐帧比较，记录输出色彩元数据；不能仅靠普通 SDR 截图判断 HDR |
| HDR/SDR | EDR 屏幕与 SDR 屏幕、HDR 开关、跨屏移动；白位与高光无明显截断、重复映射或亮度跳变；至少人工检查真实 HDR 屏幕 |
| 元数据 | 软解、硬解、拷贝解码；seek 前后及场景切换 RPU/色彩信息不中断或串帧 |
| 性能 | 指定机器上 4K 24/30fps 至少连续 10 分钟，记录渲染/解码丢帧和 CPU/GPU；预热后目标丢帧率低于 0.1%，无持续音画漂移；60fps 仅在对应样本实测后声明 |
| 功能回归 | SDR/HDR10/HLG、暂停/seek、字幕、音轨、播放列表、多窗口、全屏、画中画、截图、停止/重新打开、退出 |
| 异常 | 新后端不可用、缺失/错误元数据、损坏文件；有限重试和明确反馈，无崩溃/无限切换，无伪装成功 |
| 包安装 | oona 名称与 bundle ID、拖入安装、CLI、URL/扩展、与 IINA 并存、官方更新禁用、无 Homebrew 运行依赖、签名和 DMG 校验 |

为模式决策和回退建立真实分支测试；渲染与硬解使用媒体集成测试。测试媒体使用合法可用的小样本，用户私人视频不纳入仓库。

## 风险与待定输入

最大的未知是实验 Render API 在 macOS OpenGL 与 VideoToolbox 下的稳定性；P0 是发布前的必要可行性关口，不能提前给出确定总工期。
其次是依赖 ABI、Xcode 26.6 与当前代码兼容性、EDR 真实效果和签名资质。
待输入：用户问题视频路径/profile、主要显示器与目标机器、是否需要 Intel、是否需要可公开分发的公证包。前两项决定最终媒体验收；未答复时暂按本机 arm64 与 P5/P8 方案推进调研。

## 本轮验证与恢复锚点

- 使用 sdd-riper-one-light 和 web-access；已读项目 Agent 规则、CodeMap 与 CONTRIBUTING。
- CodeGraph status 为最新；对 MPVController、VideoView、ViewLayer、PlayerCore、Inspector、AppDelegate 和 Utility 先执行 explore 后定位源码；HDR 刷新影响涉及 PlayerWindowController 和 SidebarVideoPane，实施时纳入回归。
- 无业务代码、依赖、工程文件变更；本轮仅新增本方案文档，原初始化改动保留。
- 尚未拿到问题样本，未运行应用构建/播放/打包，所以根因仍为候选，整体功能没有宣称完成。
- 新的稳定知识候选：本机完整 Xcode 可通过 DEVELOPER_DIR 使用；目前记录在本 spec，尚未改写共享规则。
- 下一步：用户接受计划后执行 P0，先提交可行性证据，再展开 P1–P4。

## 一手来源

- [S1 Dolby bitstream profiles](https://ott.dolby.com/OnDelKits/Dolby_Vision_Online_Delivery_Kit/v1/Documentation/Specs/Visio_Profiles/help_files/topics/c_dovi_profiles.html)：profile 与兼容基层、色彩表示。
- [S2 libplacebo README](https://github.com/haasn/libplacebo/blob/master/README.md)：DV side data、reshaping、P5 转 HDR/PQ 和 SDR。
- [S3 mpv PR 16818](https://github.com/mpv-player/mpv/pull/16818)：旧 Render API gpu-next 提案、Draft 状态与审查风险。
- [S4 IINA 作者的实验 gpu-next 提交](https://github.com/lhc70000/mpv/commit/97179bce7ed980c53647d6344916f632fe689e9e)：OpenGL-next 候选接口；尚未本机验证。
- [S5 mpv manual](https://mpv.io/manual/master/)：video-params、video-out-params、video-target-params 和 DV 元数据选项。
- [S6 libplacebo renderer.h](https://github.com/haasn/libplacebo/blob/master/src/include/libplacebo/renderer.h)：当前 FEL enhancement_layer 接口；接口存在不代表发行链路已支持。
