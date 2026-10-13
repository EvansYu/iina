# oona（IINA fork）杜比视界支持 — 技术结题报告

## 目标
为 IINA 增加 DV（杜比视界 Profile 5）正确播放能力，打包为 oona.app。

## 已验证的事实链
1. DV P5 泛绿根因：IINA 走 libmpv render API（`vo=libmpv`），DV 的 RPU reshaping
   只存在于 `vo=gpu-next`（libplacebo）渲染器；IINA 的 VideoView/ViewLayer 用
   render API 无法触及 gpu-next（mpv 0.41 亦未在 render API 暴露 gpu-next）。
2. `--wid` 嵌入：mpv 在 macOS 上不支持（gpu-next 无视 wid 自建窗口，实测采样证明）。
3. ffmpeg `libplacebo` 滤镜：brew ffmpeg 未编译该滤镜，不可用。
4. dovi_tool 2.x：`convert` 仅处理双层 7→8.1，P5→8.1 转换已移除，内容侧转换不可行。
5. mpv 0.41 起 gpu-next 为默认 VO；`vo_gpu` 为遗留管线，确定无 DV 能力。

## 本分支实现的方案（oona-dv 分支）
libmpv + `vo=gpu-next` 自建窗口模式：
- MPVController：pre-init 设置 `vo=gpu-next / border=no / input-cursor=no /
  input-vo-keyboard=no / target-colorspace-hint=yes`；跳过 render context；
  teardown 相应调整；lockAndSetOpenGLContext nil 安全。
- PlayerWindowController：扫描并接管 mpv 自建窗口（CAMetalLayer 特征识别），
  borderless 化后挂为播放器窗口下层子窗口；主窗口视频区域透明化；
  按 videoView 几何同步子窗口 frame（resize/move/fileLoaded 触发）。
- VideoView：该模式下透明化（isOpaque=false、不挂 ViewLayer）。
- PlayerCore：openMainWindow 的 `force-window` 与 loadfile 移出主线程（异步）。
- 附带修复：3 处 macOS 27 `preferredImageVisibility`（SDK 26 无此符号）编译错误。

## 遇到的死锁（均已采样证实）
vo=gpu-next 建 Metal 表面必须回主线程，而 IINA 在主线程上同步读写 mpv 属性
（windowDidLoad 的 sidebar 初始化、windowScaleChanged 属性回调等）。
任何触发 vo 创建的调用（无论在哪个线程）只要与主线程的 mpv 访问并发，
即形成「vo 线程等主线程 ↔ 主线程等 core 锁」的环形死锁。

## 剩余工作（若要继续）
需要把 IINA 全部 UI 层的 mpv 属性访问改为异步/非阻塞（observe_property 化），
或在 vo 创建窗口期间暂停主线程的一切 mpv 访问并延后派发。
这是周级重构；建议关注上游 issue iina/iina#6164。

## 当前可用的替代方案（已实测）
- /Applications/mpv.app（brew mpv 0.41 + gpu-next）：右键打开方式播放 DV，
  颜色正确、字幕自动简中，配置在 ~/.config/mpv/。
- IINA 继续负责非 DV 视频。
