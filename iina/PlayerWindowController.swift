//
//  PlayerWindowController.swift
//  iina
//
//  Created by Yuze Jiang on 2/15/20.
//  Copyright © 2020 lhc. All rights reserved.
//

import Cocoa

class PlayerWindowController: NSWindowController, NSWindowDelegate {

  unowned var player: PlayerCore
  
  var videoView: VideoView {
    fatalError("Subclass must implement")
  }

  var menuActionHandler: MainMenuActionHandler!
  
  var isOntop = false {
    didSet {
      player.mpv.setFlag(MPVOption.Window.ontop, isOntop)
    }
  }
  var loaded = false
  
  let subsystem: Logger.Subsystem

  init(playerCore: PlayerCore) {
    self.player = playerCore
    subsystem = Logger.makeSubsystem("window\(player.playerNumber)", ["macwindow"])
    super.init(window: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  // Cached user defaults values
  internal lazy var followGlobalSeekTypeWhenAdjustSlider: Bool = Preference.bool(for: .followGlobalSeekTypeWhenAdjustSlider)
  internal lazy var useExactSeek: Preference.SeekOption = Preference.enum(for: .useExactSeek)
  internal lazy var relativeSeekAmount: Int = Preference.integer(for: .relativeSeekAmount)
  internal lazy var volumeScrollAmount: Int = Preference.integer(for: .volumeScrollAmount)
  internal lazy var playbackSpeedScrollAmount: Int = Preference.integer(for: .playbackSpeedScrollAmount)
  internal lazy var singleClickAction: Preference.MouseClickAction = Preference.enum(for: .singleClickAction)
  internal lazy var doubleClickAction: Preference.MouseClickAction = Preference.enum(for: .doubleClickAction)
  internal lazy var horizontalScrollAction: Preference.ScrollAction = Preference.enum(for: .horizontalScrollAction)
  internal lazy var verticalScrollAction: Preference.ScrollAction = Preference.enum(for: .verticalScrollAction)
  
  internal var observedPrefKeys: [Preference.Key] = [
    .enableToneMapping,
    .enableToneMappingParamOverride,
    .enableToneMappingTargetPeakOverride,
    .toneMappingTargetPeak,
    .loadIccProfile,
    .toneMappingAlgorithm,
    .toneMappingParamOverride,
    .toneMappingTargetPeakOverride,
    .themeMaterial,
    .showRemainingTime,
    .alwaysFloatOnTop,
    .maxVolume,
    .useExactSeek,
    .relativeSeekAmount,
    .volumeScrollAmount,
    .playbackSpeedScrollAmount,
    .singleClickAction,
    .doubleClickAction,
    .horizontalScrollAction,
    .verticalScrollAction,
    .playlistShowMetadata,
    .playlistShowMetadataInMusicMode,
    .autoSwitchToMusicMode,
  ]
  
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath, let change else { return }
    
    switch keyPath {
    case PK.enableToneMapping.rawValue,
      PK.enableToneMappingParamOverride.rawValue,
      PK.enableToneMappingTargetPeakOverride.rawValue,
      PK.toneMappingTargetPeak.rawValue,
      PK.loadIccProfile.rawValue,
      PK.toneMappingAlgorithm.rawValue,
      PK.toneMappingParamOverride.rawValue,
      PK.toneMappingTargetPeakOverride.rawValue:
      videoView.refreshEdrMode()
    case PK.themeMaterial.rawValue:
      if let newValue = change[.newKey] as? Int {
        setMaterial(Preference.Theme(rawValue: newValue))
      }
    case PK.showRemainingTime.rawValue:
      if let newValue = change[.newKey] as? Bool {
        rightLabel.mode = newValue ? .remaining : .duration
      }
    case PK.alwaysFloatOnTop.rawValue:
      if let newValue = change[.newKey] as? Bool {
        if player.info.state == .playing {
          setWindowFloatingOnTop(newValue)
        }
      }
    case PK.maxVolume.rawValue:
      if let newValue = change[.newKey] as? Int {
        volumeSlider.maxValue = Double(newValue)
        if player.mpv.getDouble(MPVOption.Audio.volume) > Double(newValue) {
          player.mpv.setDouble(MPVOption.Audio.volume, Double(newValue))
        }
      }
    case PK.useExactSeek.rawValue:
      if let newValue = change[.newKey] as? Int {
        useExactSeek = Preference.SeekOption(rawValue: newValue)!
      }
    case PK.relativeSeekAmount.rawValue:
      if let newValue = change[.newKey] as? Int {
        relativeSeekAmount = newValue.clamped(to: 1...5)
      }
    case PK.volumeScrollAmount.rawValue:
      if let newValue = change[.newKey] as? Int {
        volumeScrollAmount = newValue.clamped(to: 1...4)
      }
    case PK.playbackSpeedScrollAmount.rawValue:
      if let newValue = change[.newKey] as? Int {
        playbackSpeedScrollAmount = newValue.clamped(to: 1...4)
      }
    case PK.singleClickAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        singleClickAction = Preference.MouseClickAction(rawValue: newValue)!
      }
    case PK.doubleClickAction.rawValue:
      if let newValue = change[.newKey] as? Int {
        doubleClickAction = Preference.MouseClickAction(rawValue: newValue)!
      }
    case PK.autoSwitchToMusicMode.rawValue:
      player.overrideAutoSwitchToMusicMode = false
    default:
      return
    }
  }

  var volumeSlider: NSSlider!
  var muteButton: VolumeButton!
  var playButton: NSButton!
  var playSlider: PlaySlider!
  var rightLabel: DurationDisplayTextField!
  var leftLabel: DurationDisplayTextField!

  /** Differentiate between single clicks and double clicks. */
  internal var singleClickTimer: Timer?
  internal var mouseExitEnterCount = 0

  // Scroll direction

  /** The direction of current scrolling event. */
  enum ScrollDirection {
    case horizontal
    case vertical
  }

  internal var scrollDirection: ScrollDirection?

  /** We need to pause the video when a user starts seeking by scrolling.
   This property records whether the video is paused initially so we can
   recover the status when scrolling finished. */
  private var wasPlayingBeforeSeeking = false
  
  /** Subclasses should set these value to true if the mouse is in some
   special views (e.g. volume slider, play slider) before calling
   `super.scrollWheel()` and set them back to false after calling
   `super.scrollWheel()`.*/
  internal var seekOverride = false
  internal var volumeOverride = false

  internal var mouseActionDisabledViews: [NSView?] {[]}

  /** This variable is true when the window ready to show but waiting for size from mpv.
   In the `notifyWindowVideoSizeChanged()` call, this variable will be checked and the
   window will be shown if this variable is true.
   */
  internal var pendingShow = false

  // MARK: - Initialization

  override func windowDidLoad() {
    super.windowDidLoad()
    loaded = true
    // Issue #5319 seemed to be triggered by the window not loading. Need to know when the window
    // has loaded to be able to debug such issues.
    log("Player window has been loaded")

    guard let window else { return }
    
    // Insert `menuActionHandler` into the responder chain
    menuActionHandler = MainMenuActionHandler(playerCore: player)
    let responder = window.nextResponder
    window.nextResponder = menuActionHandler
    menuActionHandler.nextResponder = responder
    
    window.initialFirstResponder = nil
    window.titlebarAppearsTransparent = true
    
    setMaterial(Preference.enum(for: .themeMaterial))
    
    addObserver(to: .default, forName: .iinaMediaTitleChanged, object: player) { [unowned self] _ in
        self.updateTitle()
    }

    self.playButton = NSButton(image: .play, target: self, action: #selector(playButtonAction))
    playButton.alternateImage = .pause

    self.muteButton = VolumeButton(player: player, target: self, action: #selector(muteButtonAction))
    muteButton.size(width: 24, height: 24)

    self.volumeSlider = VolumeSlider()
    volumeSlider.translatesAutoresizingMaskIntoConstraints = false
    volumeSlider.refusesFirstResponder = true
    volumeSlider.controlSize = .mini
    volumeSlider.minValue = 0
    volumeSlider.maxValue = Double(Preference.integer(for: .maxVolume))
    volumeSlider.target = self
    volumeSlider.action = #selector(volumeSliderChanges)

    self.playSlider = PlaySlider()
    playSlider.translatesAutoresizingMaskIntoConstraints = false
    playSlider.refusesFirstResponder = true
    playSlider.minValue = 0
    playSlider.maxValue = 100
    playSlider.target = self
    playSlider.action = #selector(playSliderChanges)

    self.leftLabel = DurationDisplayTextField(labelWithString: "-:--:--")
    self.rightLabel = DurationDisplayTextField(labelWithString: "-:--:--")
    [leftLabel, rightLabel].forEach { label in
      label!.translatesAutoresizingMaskIntoConstraints = false
      label!.controlSize = .mini
      label!.setContentHuggingPriority(.init(251), for: .horizontal)
      label!.wantsLayer = true
    }

    leftLabel.mode = .current
    rightLabel.mode = Preference.bool(for: .showRemainingTime) ? .remaining : .duration

    updateVolume()

    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }

    addObserver(to: .default, forName: .iinaFileLoaded, object: player) { [unowned self] _ in
      self.updateTitle()
      // oona: 文件加载后视频窗口才会被 mpv 创建，此时（重新）启动托管扫描。
      if self is MainWindowController {
        self.hostMPVVideoWindowIfNeeded()
      }
    }

    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [unowned self] _ in
      if Preference.bool(for: .pauseWhenGoesToSleep) {
        self.player.pause()
      }
    }

    addObserver(to: .default, forName: NSScreen.colorSpaceDidChangeNotification, object: nil) { [unowned self] noti in
      player.refreshEdrMode()
    }
  }

  deinit {
    ObjcUtils.silenced {
      for key in self.observedPrefKeys {
        UserDefaults.standard.removeObserver(self, forKeyPath: key.rawValue)
      }
    }
  }

  internal func addObserver(to notificationCenter: NotificationCenter, forName name: Notification.Name, object: Any? = nil, using block: @escaping (Notification) -> Void) {
    notificationCenter.addObserver(forName: name, object: object, queue: .main, using: block)
  }

  internal func setMaterial(_ theme: Preference.Theme?) {
    guard let window, let theme else { return }

    window.appearance = NSAppearance(iinaTheme: theme)
    window.backgroundColor = window.effectiveAppearance.isDark ? .black : .white
  }

  // MARK: - Mouse / Trackpad events


  @discardableResult
  func handleKeyBinding(_ keyBinding: KeyMapping) -> Bool {
    if keyBinding.isIINACommand {
      // - IINA command
      if let iinaCommand = IINACommand(rawValue: keyBinding.rawAction) {
        handleIINACommand(iinaCommand)
        return true
      } else {
        log("Unknown iina command \(keyBinding.rawAction)", level: .error)
        return false
      }
    } else {
      // - mpv command
      let returnValue: Int32
      // execute the command
      switch keyBinding.action.first! {

      case MPVCommand.abLoop.rawValue:
        abLoop()
        returnValue = 0

      case MPVCommand.quit.rawValue:
        // Initiate application termination. AppKit requires this be done from the main thread,
        // however the main dispatch queue must not be used to avoid blocking the queue as per
        // instructions from Apple. IINA must support quitting being initiated by mpv as the user
        // could use mpv's IPC interface to send the quit command directly to mpv. However the
        // shutdown sequence is cleaner when initiated by IINA, so we do not send the quit command
        // to mpv and instead trigger the normal app termination sequence.
        RunLoop.main.perform(inModes: [.common]) {
          NSApp.terminate(nil)
        }
        returnValue = 0

      case MPVCommand.screenshot.rawValue:
        return player.screenshot(fromKeyBinding: keyBinding)

      default:
        returnValue = player.mpv.command(rawString: keyBinding.rawAction)
      }

      if returnValue == 0 {
        return true
      } else {
        log("Return value \(returnValue) when executing key command \(keyBinding.rawAction)", level: .error)
        return false
      }
    }
  }

  func abLoop() {
    player.abLoop()
    syncSlider()
  }

  func syncSlider() {
    let a = player.abLoopA
    playSlider.abLoopA.isHidden = a == 0
    playSlider.abLoopA.doubleValue = secondsToPercent(a)
    let b = player.abLoopB
    playSlider.abLoopB.isHidden = b == 0
    playSlider.abLoopB.doubleValue = secondsToPercent(b)
    playSlider.needsDisplay = true
  }

  /// Returns the percent of the total duration of the video the given position in seconds represents.
  ///
  /// The percentage returned must be considered an estimate that could change. The duration of the video is obtained from the
  /// [mpv](https://mpv.io/manual/stable/) `duration` property. The documentation for this property cautions that mpv
  /// is not always able to determine the duration and when it does return a duration it may be an estimate. If the duration is unknown
  /// this method will fallback to using the current playback position, if that is known. Otherwise this method will return zero.
  /// - Parameter seconds: Position in the video as seconds from start.
  /// - Returns: The percent of the video the given position represents.
  private func secondsToPercent(_ seconds: Double) -> Double {
    if let duration = player.info.videoDuration?.second {
      return duration == 0 ? 0 : seconds / duration * 100
    } else if let position = player.info.videoPosition?.second {
      return position == 0 ? 0 : seconds / position * 100
    } else {
      return 0
    }
  }

  override func keyDown(with event: NSEvent) {
    let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
    let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)
    
    PluginInputManager.handle(
      input: normalizedKeyCode, event: .keyDown, player: player,
      arguments: keyEventArgs(event), handler: {
      if let kb = PlayerCore.keyBindings[normalizedKeyCode] {
        self.handleKeyBinding(kb)
        return true
      }
      return false
    }, defaultHandler: {
      super.keyDown(with: event)
    })
  }
  
  override func keyUp(with event: NSEvent) {
    let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
    let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)
    
    PluginInputManager.handle(
      input: normalizedKeyCode, event: .keyUp, player: player,
      arguments: keyEventArgs(event)
    )
  }
  
  
  override func mouseDown(with event: NSEvent) {
    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseDown,
      player: player, arguments: mouseEventArgs(event)
    )
    // we don't call super here because before adding the plugin system,
    // MainWindowController didn't call super at all
  }

  override func mouseUp(with event: NSEvent) {
    guard !event.inAnyOf(mouseActionDisabledViews) else { return }

    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: { [self] in
      // default handler
      if event.clickCount == 1 {
        if doubleClickAction == .none {
          performMouseAction(singleClickAction)
        } else {
          singleClickTimer = Timer.scheduledTimer(timeInterval: NSEvent.doubleClickInterval, target: self, selector: #selector(performMouseActionLater), userInfo: singleClickAction, repeats: false)
          mouseExitEnterCount = 0
        }
      } else if event.clickCount == 2 {
        if let timer = singleClickTimer {
          timer.invalidate()
          singleClickTimer = nil
        }
        performMouseAction(doubleClickAction)
      }
    })
  }

  /// This method is provided soly for invoking plugin input handlers.
  func informPluginMouseDragged(with event: NSEvent) {
    PluginInputManager.handle(
      input: PluginInputManager.Input.mouse, event: .mouseDrag, player: player,
      arguments: mouseEventArgs(event)
    )
  }

  override func rightMouseDown(with event: NSEvent) {
    PluginInputManager.handle(
      input: PluginInputManager.Input.rightMouse, event: .mouseDown,
      player: player, arguments: mouseEventArgs(event)
    )
  }

  override func rightMouseUp(with event: NSEvent) {
    guard !event.inAnyOf(mouseActionDisabledViews) else { return }

    PluginInputManager.handle(
      input: PluginInputManager.Input.rightMouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: {
      self.performMouseAction(Preference.enum(for: .rightClickAction))
    })
  }

  override func otherMouseUp(with event: NSEvent) {
    guard !event.inAnyOf(mouseActionDisabledViews) else { return }
    
    PluginInputManager.handle(
      input: PluginInputManager.Input.otherMouse, event: .mouseUp, player: player,
      arguments: mouseEventArgs(event), defaultHandler: {
      if event.type == .otherMouseUp {
        self.performMouseAction(Preference.enum(for: .middleClickAction))
      } else {
        super.otherMouseUp(with: event)
      }
    })
  }

  internal func performMouseAction(_ action: Preference.MouseClickAction) {
    switch action {
    case .pause:
      player.togglePause()
    default:
      break
    }
  }
  
  override func scrollWheel(with event: NSEvent) {
    let isMouse = event.phase.isEmpty
    let isTrackpadBegan = event.phase.contains(.began)
    let isTrackpadEnd = event.phase.contains(.ended)

    // determine direction

    if isMouse || isTrackpadBegan {
      if event.scrollingDeltaX != 0 {
        scrollDirection = .horizontal
      } else if event.scrollingDeltaY != 0 {
        scrollDirection = .vertical
      }
    } else if isTrackpadEnd {
      scrollDirection = nil
    }

    let scrollAction: Preference.ScrollAction
    if seekOverride {
      scrollAction = .seek
    } else if volumeOverride {
      scrollAction = .volume
    } else {
      scrollAction = scrollDirection == .horizontal ? horizontalScrollAction : verticalScrollAction
      // show volume popover when volume seek begins and hide on end
      if let miniPlayer = self as? MiniPlayerWindowController, scrollAction == .volume {
        miniPlayer.handleVolumePopover(isTrackpadBegan, isTrackpadEnd, isMouse)
      }
    }

    // pause video when seek begins

    if scrollAction == .seek && isTrackpadBegan {
      // record pause status
      if player.info.state == .playing {
        player.pause()
        wasPlayingBeforeSeeking = true
      }
    }

    if isTrackpadEnd && wasPlayingBeforeSeeking {
      // only resume playback when it was playing before seeking
      if wasPlayingBeforeSeeking {
        player.resume()
      }
      wasPlayingBeforeSeeking = false
    }

    // handle the delta value

    let isPrecise = event.hasPreciseScrollingDeltas
    let isNatural = event.isDirectionInvertedFromDevice

    var deltaX = isPrecise ? Double(event.scrollingDeltaX) : event.scrollingDeltaX.unifiedDouble
    var deltaY = isPrecise ? Double(event.scrollingDeltaY) : event.scrollingDeltaY.unifiedDouble * 2

    if isNatural {
      deltaY = -deltaY
    } else {
      deltaX = -deltaX
    }

    let delta = scrollDirection == .horizontal ? deltaX : deltaY

    // perform action
    
    switch scrollAction {
    case .seek:
      let seekAmount = (isMouse ? AppData.seekAmountMapMouse : AppData.seekAmountMap)[relativeSeekAmount] * delta
      player.seek(relativeSecond: seekAmount, option: useExactSeek)
    case .volume:
      // don't use precised delta for mouse
      let newVolume = player.info.volume + (isMouse ? delta : AppData.volumeMap[volumeScrollAmount] * delta)
      player.setVolume(newVolume)
      volumeSlider.doubleValue = newVolume
    case .playbackSpeed:
      let min = 0.05
      let max = 4.0
      let newSpeed = round(1000 * (player.info.playSpeed + (player.info.playSpeed * AppData.playbackSpeedMap[playbackSpeedScrollAmount] * delta)).clamped(to: min...max)) / 1000
      player.setSpeed(newSpeed)
    default:
      break
    }
  }

  /**
   Being called to perform single click action after timeout.

   - SeeAlso:
   mouseUp(with:)
   */
  @objc internal func performMouseActionLater(_ timer: Timer) {
    guard let action = timer.userInfo as? Preference.MouseClickAction else { return }
    if mouseExitEnterCount >= 2 && action == .hideOSC {
      // the counter being greater than or equal to 2 means that the mouse re-entered the window
      // `showUI()` must be called due to the movement in the window, thus `hideOSC` action should be cancelled
      return
    }
    performMouseAction(action)
  }
  
  // MARK: - Window delegate: Activeness status

  func windowDidBecomeMain(_ notification: Notification) {
    PlayerCore.lastActive = player
    NowPlayingInfoManager.shared.updateInfo(withTitle: true)
    AppDelegate.shared.menuController?.updatePluginMenu()

    NotificationCenter.default.post(name: .iinaMainWindowChanged, object: true)

    // oona: 播放器主窗口激活时接管 mpv 视频子窗口（迷你播放器窗口不参与）。
    if self is MainWindowController {
      hostMPVVideoWindowIfNeeded()
    }
  }

  /// The window changed its occlusion state.
  ///
  /// If the entire window is now occluded then no action is needed. But if the window has become visible then the view may need to
  /// be drawn.
  /// - Note: The window [isVisible](https://developer.apple.com/documentation/appkit/nswindow/isvisible)
  ///     property is intentionally not used. That property is `true` even when the window is fully obscured. Instead the
  ///     [occlusionState](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property)
  ///     property is used as it will not indicate the window is visible when it is obscured by other windows.
  func windowDidChangeOcclusionState(_ notification: Notification) {
    guard let window, window.occlusionState.contains(.visible) else { return }
    forceDraw("window became visible")
  }

  func windowDidResignMain(_ notification: Notification) {
    NotificationCenter.default.post(name: .iinaMainWindowChanged, object: false)
  }

  func windowDidChangeScreen(_ notification: Notification) {
    videoView.updateDisplayLink()
    syncMPVVideoWindowFrame()
  }

  // MARK: - oona: mpv gpu-next 自建窗口托管

  /// mpv（vo=gpu-next 自建窗口模式）创建的视频窗口。
  private var mpvVideoWindow: NSWindow?
  /// 从 mpv 窗口取出并重挂载到 videoView 的视频视图。
  private var mpvVideoView: NSView?
  private var mpvWindowSearchTimer: Timer?
  private var mpvFrameChangeObserver: NSObjectProtocol?
  /// oona 诊断：扫描次数计数（用于周期性输出窗口清单）。
  private var scanDumpCounter = 0
  /// 托管启动时已知窗口的快照；mpv 的窗口 = 之后新出现的可见普通层级窗口。
  private var knownWindowsAtScanStart: Set<ObjectIdentifier> = []

  /// 开始扫描并接管 mpv 自建的视频窗口（详见 `hostMPVVideoWindowScan`）。
  /// - Note: mpv 在首个视频帧输出时才创建窗口，因此需要在播放开始后调用；
  ///     内部以 0.5s 轮询直到接管成功或超时（30s）。
  func hostMPVVideoWindowIfNeeded() {
    guard MPVController.useGPUNextOwnWindow else { return }
    if mpvWindowSearchTimer == nil {
      if knownWindowsAtScanStart.isEmpty {
        knownWindowsAtScanStart = Set(NSApp.windows.map { ObjectIdentifier($0) })
      }
      videoView.postsFrameChangedNotifications = true
      mpvFrameChangeObserver = NotificationCenter.default.addObserver(
        forName: NSView.frameDidChangeNotification, object: videoView, queue: .main
      ) { [weak self] _ in
        // oona: 视图重挂载方案下同步 Metal drawable 尺寸（窗口几何由视图层级自动处理）。
        self?.syncDrawableSize()
      }
      let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(mpvWindowScanTimerFired),
                        userInfo: nil, repeats: true)
      RunLoop.main.add(timer, forMode: .common)
      mpvWindowSearchTimer = timer
    }
    hostMPVVideoWindowScan()
  }

  @objc private func mpvWindowScanTimerFired() {
    hostMPVVideoWindowScan()
    if mpvVideoWindow != nil, let timer = mpvWindowSearchTimer {
      timer.invalidate()
      mpvWindowSearchTimer = nil
    }
  }

  /// 识别 mpv 自建的窗口（contentView 层级中含 CAMetalLayer），把它的
  /// contentView（承载 Vulkan/Metal 表面的视图）重新挂载到 IINA 的 videoView 里。
  ///
  /// 视图重挂载（reparent）而不是子窗口+主窗口透明化：后者依赖 AppKit 窗口服务
  /// 器的透明合成（实测被主题/背景色设置等干扰，导致黑屏），而视图作为
  /// videoView 的子视图直接参与绘制，OSD/OSC 等兄弟视图天然覆盖其上。
  private func hostMPVVideoWindowScan() {
    guard mpvVideoWindow == nil, let playerWindow = window else { return }
    if knownWindowsAtScanStart.isEmpty {
      knownWindowsAtScanStart = Set(NSApp.windows.map { ObjectIdentifier($0) })
    }
    guard let candidate = NSApp.windows.first(where: { w in
      guard w !== playerWindow, w.isVisible, w.level == .normal else { return false }
      guard !knownWindowsAtScanStart.contains(ObjectIdentifier(w)) else { return false }
      // 排除 IINA 自己的窗口类型（mpv 创建的是普通 NSWindow）。
      guard !(w is MainWindow), !(w is MiniPlayerWindow), !(w is NSPanel) else { return false }
      return true
    }) else {
      // oona 诊断：每 4 次扫描（约 2s）输出一次窗口清单，定位匹配失败原因。
      scanDumpCounter += 1
      if scanDumpCounter % 4 == 0 {
        let summary = NSApp.windows.map { w -> String in
          let cvDesc: String
          if let cv = w.contentView {
            let layerDesc = cv.layer.map { String(describing: type(of: $0)) } ?? "nil"
            let subs = (cv.layer?.sublayers ?? []).map { String(describing: type(of: $0)) }.joined(separator: ",")
            cvDesc = "\(String(describing: type(of: cv)))[\(layerDesc){\(subs)}]"
          } else {
            cvDesc = "nil"
          }
          return "\(String(describing: type(of: w)))|vis=\(w.isVisible)|lvl=\(w.level.rawValue)|cv=\(cvDesc)"
        }.joined(separator: "\n    ")
        Logger.log("oona: 窗口清单（\(NSApp.windows.count) 个）：\n    \(summary)", level: .debug, subsystem: subsystem)
      }
      return
    }
    Logger.log("oona: 找到 mpv 视频窗口，重挂载其 contentView 到 videoView", subsystem: subsystem)
    mpvVideoWindow = candidate
    // mpv 可能随时销毁该窗口；防止窗口关闭时连带释放已被我们接管的视图。
    candidate.isReleasedWhenClosed = false
    if let mpvView = candidate.contentView {
      // 用占位视图替换，解除窗口对 mpvView 的持有，然后藏起空窗口。
      candidate.contentView = NSView(frame: .zero)
      candidate.orderOut(nil)
      // mpv 的视图实现自己的鼠标/键盘响应（会吞掉事件），包一层 hitTest 透传容器，
      // 让 videoView 继续拿到全部交互（点击暂停、双击全屏、拖拽等）。
      let eater = MPVEventEaterView(frame: videoView.bounds)
      eater.autoresizingMask = [.width, .height]
      videoView.addSubview(eater)
      eater.addSubview(mpvView)
      mpvView.frame = eater.bounds
      mpvView.autoresizingMask = [.width, .height]
      mpvVideoView = mpvView
      syncDrawableSize()
    }
    // oona: 窗口已创建并接管 = vo 初始化完成，放行主线程上延迟的 mpv 回调。
    player.mpv.markVideoReady()
  }

  /// 同步 mpv 视图层（CAMetalLayer）的 drawableSize 到当前视图尺寸。
  func syncDrawableSize() {
    guard let mpvView = mpvVideoView else { return }
    // CAMetalLayer 可能是视图自身的 layer，也可能是其子 layer。
    var metalLayer = mpvView.layer as? CAMetalLayer
    if metalLayer == nil, let subs = mpvView.layer?.sublayers {
      metalLayer = subs.first(where: { $0 is CAMetalLayer }) as? CAMetalLayer
    }
    guard let metalLayer else { return }
    let scale = videoView.window?.backingScaleFactor ?? 2.0
    let size = CGSize(width: videoView.bounds.width * scale, height: videoView.bounds.height * scale)
    if metalLayer.drawableSize != size {
      metalLayer.drawableSize = size
    }
  }

  /// 兼容保留：视图重挂载方案不再需要同步子窗口几何。
  func syncMPVVideoWindowFrame() {}

  // MARK: - UI

  func setupUI() {
    player.syncUI([.time, .playButton, .volume])
  }

  @objc
  func updateTitle() {
    fatalError("Must implement in the subclass")
  }
  
  func updateVolume() {
    volumeSlider.doubleValue = player.info.volume
    muteButton.update()
  }
  
  func updatePlayTime(withDuration: Bool, andProgressBar: Bool) {
    // IINA listens for changes to mpv properties such as chapter that can occur during file loading
    // resulting in this function being called before mpv has set its position and duration
    // properties. Confirm the window and file have been loaded.
    guard loaded, player.info.state.loaded else { return }
    // The mpv documentation for the duration property indicates mpv is not always able to determine
    // the video duration in which case the property is not available.
    guard let duration = player.info.videoDuration else {
      log("Video duration not available", level: .warning)
      return
    }
    guard let pos = player.info.videoPosition else {
      log("Video position not available", level: .warning)
      return
    }
    guard let remaining = player.info.videoRemaining else {
      log("Video remaining not available", level: .warning)
      return
    }
    [leftLabel, rightLabel].forEach { $0.updateText(with: duration, given: pos, and: remaining) }
    player.touchBarSupport.touchBarPosLabels.forEach { $0.updateText(with: duration, given: pos,
                                                                     and: remaining) }
    if andProgressBar {
      let percentage = (pos.second / duration.second) * 100
      playSlider.doubleValue = percentage
      player.touchBarSupport.touchBarPlaySlider?.setDoubleValueSafely(percentage)
    }
  }
  
  func updatePlayButtonState(paused: Bool) {
    guard loaded else { return }
    playButton.image = NSImage(named: paused ? "play" : "pause")
  }

  /** This method will not set `isOntop`! */
  func setWindowFloatingOnTop(_ onTop: Bool, updateOnTopStatus: Bool = true) {
    guard let window else { return }
    window.level = onTop ? .iinaFloating : .normal
    if (updateOnTopStatus) {
      self.isOntop = onTop
    }
  }

  func handleVideoSizeChange() {
    fatalError("Must implement in the subclass")
  }

  /// Force a draw, if needed.
  ///
  /// If a video is actively being played then there is no need to force a draw as the view is actively being drawn. Otherwise the view
  /// must be drawn. Video tracks can be images or cover art. Even when there isn't a video track drawing sometimes must be forced
  /// to clear a previous image, such as when an audio only file is played in the main window after it was used to play a video.
  /// - Parameters:
  ///   - reason: Reason for forcing drawing.
  ///   - always: Draw even when playback is in progress and there isn't a video track. Used to clear any previous image.
  func forceDraw(_ reason: String, always: Bool = false) {
    guard player.info.state.active else { return }
    if !always {
      let notVideo = player.info.currentTrack(.video)?.isImage ?? true
      guard player.info.state == .paused || notVideo else { return }
    }
    log("Forcing drawing, \(reason)")
    videoView.videoLayer.update(force: true)
  }

  // MARK: - IBActions

  @IBAction func volumeSliderChanges(_ sender: NSSlider) {
    let value = sender.doubleValue
    if Preference.double(for: .maxVolume) > 100, value > 100 && value < 101 {
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }
    player.setVolume(value)
  }

  @IBAction func playButtonAction(_ sender: NSButton) {
    player.info.state == .paused ? player.resume() : player.pause()
  }

  @IBAction func muteButtonAction(_ sender: NSButton) {
    player.toggleMute()
  }

  @IBAction func playSliderChanges(_ sender: NSSlider) {
    guard player.info.state.active else { return }
    let percentage = 100 * sender.doubleValue / sender.maxValue
    player.seek(percent: percentage, forceExact: !followGlobalSeekTypeWhenAdjustSlider)
  }

  internal func handleIINACommand(_ cmd: IINACommand) {
    switch cmd {
    case .openFile:
      AppDelegate.shared.openFile(self)
    case .openURL:
      AppDelegate.shared.openURL(self)
    case .deleteCurrentFile:
      menuActionHandler.menuDeleteCurrentFile(.dummy)
    case .deleteCurrentFileHard:
      menuActionHandler.menuDeleteCurrentFileHard(.dummy)
    default:
      break
    }
  }

  // MARK: - Utils

  func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: subsystem)
  }
}


fileprivate func mouseEventArgs(_ event: NSEvent) -> [[String: Any]] {
  return [[
    "x": event.locationInWindow.x,
    "y": event.locationInWindow.y,
    "clickCount": event.clickCount,
    "pressure": event.pressure
  ] as [String : Any]]
}

fileprivate func keyEventArgs(_ event: NSEvent) -> [[String: Any]] {
  return [[
    "x": event.locationInWindow.x,
    "y": event.locationInWindow.y,
    "isRepeat": event.isARepeat
  ] as [String : Any]]
}

// MARK: - oona: mpv 视图事件透传容器

/// 包住 mpv 的视频视图，把所有命中测试转给父视图（videoView），
/// 避免 mpv 的响应链吞掉 IINA 的鼠标/键盘交互。
final class MPVEventEaterView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    superview
  }
}
