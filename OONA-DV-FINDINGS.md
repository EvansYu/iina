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

## 追记：vo-prewarm 架构（第 5 轮迭代）

### 已验证可行
- vo 在启动时由核心线程创建（force-window=yes pre-init + 主线程空闲服务窗口派发）
- 每核心窗口标题 "oona-mpv-N" 精确匹配，托管 T+1s 完成
- 子窗口挂载 + 几何同步（640x400 → videoView 矩形）正常

### 第 5 个死锁变体（本架构仍未根治）
门控冲刷的 fileStarted 回调在主线程调 getMediaTitle；此刻 core 处于
play_current_file/load_external_opts 中，dispatch 队列状态阻塞外部 API——
所有 mpv 线程空闲、主线程+IPC 永久卡在 mp_dispatch_lock（采样证实）。

### 死锁分类学（5 个样本的共同根因）
IINA 在主线程同步调用 mpv API（数十个入口：标题/侧栏/NowPlaying/事件回调…）
× mpv mac-vo 在窗口创建/重配置期间需要主线程参与调度。
门控只能延迟"事件驱动"的回调，无法覆盖直接调用入口。

### 唯一根治路径
把 IINA 的 mpv 访问层全面异步化（observe_property 缓存 + async 读），
主线程永不等待 core 锁——即最初评估的"周级、多会话"重构。

## 终局结论（第 7 个采样后）

### 完整证据链
mpv 日志：文件打开完成（1.087s）→ 播放从未开始（"Playing" 计数 = 0）→ 无任何错误。

主线程 100% 采样路径：
```
RunLoop 块(sidChanged) → performMPVCall → 泵送 → 排空主队列
→ 主队列块(fileStarted) → getMediaTitle → performMPVCall → 泵送
→ 排空主队列 → 更多 mpv 调用块 → ... 无界级联
```
vo 线程卡点（第 6 采样）：`run_reconfig → MacCommon.config → DispatchQueue.main.sync`。

### 机理定论
mpv 的 Swift 层（MacCommon）在 vo 重配置期间，持有 core 派发锁的同时向
主队列同步派发。嵌入方（IINA）的任何主线程 mpv 调用在此期间会：
- 占用主队列 → mpv 的 dispatch_sync 永不完成（串行队列不可重入）；或
- 经泵送排空主队列 → 级联更多 mpv 调用 → 活锁
且 core 派发锁在特定并发序列下进入"所有内部线程空闲、外部调用永久阻塞"的
卡死态（第 5/7 采样证实，先于嵌入方任何机制存在）。

这是 libmpv + vo=gpu-next 自建窗口在 macOS 上的组合问题（上游几乎无人测试
此路径：独立 mpv 二进制的主循环结构与嵌入完全不同）。**嵌入方无法根治，
需要 mpv 上游修复（MacCommon.config 的同步派发改为异步/免锁）。**

### 交付物
- 本分支：完整的 4 代架构实现 + 死锁分类学（7 样本）
- 用户可用方案：/Applications/mpv.app（DV 完美）+ IINA（日常）
- 建议上游 issue：向 mpv 报告 libmpv+macvk+force-window 的 dispatch 卡死

## 第二阶段研究（第 35 轮）：关键反转与新证据

### 最小复现框架（other/oona-research/minitest.swift）
dlopen libmpv + vo=gpu-next 自建窗口 + 可注入 IINA 行为特征（事件读取/
属性观察/双实例/加载序列/读频率/泵送），带 --pump --queue-block 等开关。

### 三个决定性实验结果
1. **"mpv 内部 bug"结论被推翻**：最小 libmpv 程序 + vo=gpu-next 自建窗口
   完全健康（含事件读取、观察、双实例、硬解、IINA 加载序列）。
2. **卡死真变量 = 主线程读频率**：0.05s 间隔 100% 复现，0.2s 偶发。
   与硬解无关（hwdec=no 同样卡）。
3. **泵送（performMPVCall）机制本身有效**——但仅限"运行循环源"上下文：
   - Timer/performSelector 上下文中的泵送读：健康 ✓
   - GCD 主队列块中的泵送读：卡死 ✗（串行队列不可重入，无法排空）
   注意：RunLoop.perform 在现代 macOS 上也是 GCD 主队列支撑，无效。

### 泵送引入的新问题：重入崩溃
泵送运行循环执行排队回调 → trackListChanged 重入 getTrackInfo →
非递归锁递归获取 → SIGTRAP。已加"泵送期间推迟重入块"防护，但防护
引入了新的调度级联，托管路径失灵（37s+）。

### 剩余工作（明确但量大）
1. IINA 的 NotificationCenter 观察者（queue:.main）与 DispatchQueue.main.async
   调用点全部转为 performSelector 调度（数百处）
2. 审计"持锁跨 mpv 调用"的代码（trackList 等）
3. 或：等待 mpv 上游把 MacCommon.config 的 dispatch_sync 改异步

## 终局补充（第 36 轮）：系统对话框插曲与最终验证

### 关键插曲
build28 的崩溃使 macOS 记住"应用反复崩溃"，之后每次启动被
`promptToIgnorePersistentState → NSAlert.runModal` 系统模态框阻塞
（弹窗常被遮挡/在副屏，用户看不到）——第 32-35 轮的"启动失败"全是它，
并非代码回归。换 bundle ID（app.oona.player2）+ NSSupportsPersistentWindowState=false 解决。

### 最终验证（清除对话框干扰后）
- 启动链完整：托管 1-2s 完成（找到窗口→挂载→几何同步）✓
- vo reconfig 成功：`3840x2160 videotoolbox[p010] dolbyvision/bt.2020/pq` ✓
- 但播放仍未启动：vo 线程卡 `MacCommon.config → dispatch_sync(主队列)`，
  主线程在 syncUI Timer 泵送中——最小复现（Timer 泵送+0.05s 读）健康，
  但 oona 完整复杂度（事件观察者风暴 + 多定时器 + 延迟盒机制）下仍死锁。
- 结论不变：mpv 的 MacCommon.config 持 core 锁同步派发主队列是根因，
  嵌入侧（泵送/门控/延迟盒/调度器）已穷尽，需 mpv 上游修复。
