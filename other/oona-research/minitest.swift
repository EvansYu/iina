import AppKit

// ===== libmpv C API via dlsym =====
setbuf(stdout, nil)
let h = dlopen("/opt/homebrew/opt/mpv/lib/libmpv.2.dylib", RTLD_NOW)!
func sym<T>(_ name: String) -> T { unsafeBitCast(dlsym(h, name), to: T.self) }

typealias CreateFn = @convention(c) () -> OpaquePointer?
typealias SetOptFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
typealias InitFn = @convention(c) (OpaquePointer?) -> Int32
typealias CommandFn = @convention(c) (OpaquePointer?, UnsafePointer<UnsafePointer<CChar>?>?) -> Int32
typealias GetPropStrFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
typealias FreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
typealias WaitEventFn = @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
typealias TerminateFn = @convention(c) (OpaquePointer?) -> Void

let mpv_create = sym("mpv_create") as CreateFn
let mpv_set_option_string = sym("mpv_set_option_string") as SetOptFn
let mpv_initialize = sym("mpv_initialize") as InitFn
let mpv_command = sym("mpv_command") as CommandFn
let mpv_get_property_string = sym("mpv_get_property_string") as GetPropStrFn
let mpv_free = sym("mpv_free") as FreeFn
let mpv_wait_event = sym("mpv_wait_event") as WaitEventFn
let mpv_terminate_destroy = sym("mpv_terminate_destroy") as TerminateFn
typealias SetWakeupFn = @convention(c) (OpaquePointer?, @convention(c) (UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?) -> Void
typealias ObserveFn = @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>, Int32) -> Int32
let mpv_set_wakeup_callback = sym("mpv_set_wakeup_callback") as SetWakeupFn
let mpv_observe_property = sym("mpv_observe_property") as ObserveFn

let useReader = CommandLine.arguments.contains("--reader")
let useObserve = CommandLine.arguments.contains("--observe")
let useTwo = CommandLine.arguments.contains("--two")
let useHwdec = CommandLine.arguments.contains("--hwdec")
let noStress = CommandLine.arguments.contains("--no-stress")
let usePump = CommandLine.arguments.contains("--pump")
let useQueueBlock = CommandLine.arguments.contains("--queue-block")
var pumpQueue = DispatchQueue(label: "pump", qos: .userInitiated, attributes: .concurrent)
func pumpedRead() -> Bool {
    guard usePump else {
        guard let s = mpv_get_property_string(mpvHandleGlobal, "time-pos") else { return false }
        mpv_free(s)
        return true
    }
    var ok = false
    let done = DispatchSemaphore(value: 0)
    pumpQueue.async {
        if let s = mpv_get_property_string(mpvHandleGlobal, "time-pos") { mpv_free(s); ok = true }
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return ok
}
let useIinaLoad = CommandLine.arguments.contains("--iina-load")

var readerQueue = DispatchQueue(label: "reader", qos: .userInitiated)
var mpvHandleGlobal: OpaquePointer!
func drainEvents() {
    guard mpvHandleGlobal != nil else { return }
    while let ev = mpv_wait_event(mpvHandleGlobal, 0.05) {
        let eventId = ev.load(as: Int32.self)
        if eventId == 0 { break }
        if eventId == 1 { exit(3) }
    }
}

// ===== 宿主 UI =====
let F = "/Users/yuhb/Downloads/movie/MobLand.2025.S02.2160p.PMTP.WEB-DL.DDP5.1.DV.H.265-SmartWeb/MobLand.2025.S02E01.2160p.PMTP.WEB-DL.DDP5.1.DV.H.265-SmartWeb.mkv"
let useWid = CommandLine.arguments.contains("--wid")

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let rect = NSRect(x: 100, y: 100, width: 800, height: 450)
let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
let container = NSView(frame: rect)
container.wantsLayer = true
win.contentView = container
win.title = "MINIMAL LIBMPV HOST"
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

// ===== mpv init =====
let mpv = mpv_create()!
mpvHandleGlobal = mpv
print("mpv handle created")
func setopt(_ k: String, _ v: String) { _ = mpv_set_option_string(mpv, k, v) }
setopt("vo", "gpu-next")
setopt("input-cursor", "no")
if useHwdec {
    let mode = CommandLine.arguments.first(where: { $0.hasPrefix("--hwdec-mode=") })?
        .replacingOccurrences(of: "--hwdec-mode=", with: "") ?? "auto-safe"
    setopt("hwdec", mode)
    print("hwdec=\(mode)")
}
setopt("input-vo-keyboard", "no")
setopt("title", "minitest-mpv")
if useWid {
    let ptr = UInt(bitPattern: Unmanaged.passUnretained(container).toOpaque())
    setopt("wid", "\(ptr)")
}
print("calling mpv_initialize...")
print("init result: \(mpv_initialize(mpv))")

// loadfile（strdup 保证指针生命周期）
var cArgs: [UnsafePointer<CChar>?] = ["loadfile", F].map { (s: String) -> UnsafePointer<CChar>? in
    let p = strdup(s)
    return p.map { UnsafePointer($0) }
}
cArgs.append(nil)
if useIinaLoad {
    // IINA openMainWindow 的序列：读 pause → 设 pause=true → loadfile → 1.5s 后 pause=false
    let pauseStr = mpv_get_property_string(mpv, "pause")
    let curPause = pauseStr.map { String(cString: $0) } ?? "no"
    mpv_free(pauseStr)
    print("current pause: \(curPause)")
    setopt("pause", "yes")
    print("pre-load pause set")
}
let cmdResult = cArgs.withUnsafeBufferPointer { mpv_command(mpv, $0.baseAddress) }
print("loadfile result: \(cmdResult)")
if useIinaLoad {
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        setopt("pause", "no")
        print("post-load unpause (bg thread)")
    }
}
cArgs.compactMap { $0 }.forEach { free(UnsafeMutableRawPointer(mutating: $0)) }

// ===== IINA 行为特征注入 =====
if useObserve {
    for (i, prop) in ["pause", "time-pos", "sid", "video-params", "duration",
                      "playlist-count", "track-list", "chapter-list", "volume", "mute"].enumerated() {
        _ = mpv_observe_property(mpv, UInt64(i), prop, 5 /*MPV_FORMAT_NODE*/)
    }
    print("observers registered")
}
if useReader {
    let wakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
        readerQueue.async { drainEvents() }
    }
    mpv_set_wakeup_callback(mpv, wakeup, nil)
    print("wakeup callback + reader armed")
}
if useTwo {
    let mpv2 = mpv_create()!
    _ = mpv_set_option_string(mpv2, "vo", "gpu-next")
    _ = mpv_set_option_string(mpv2, "force-window", "yes")
    _ = mpv_set_option_string(mpv2, "title", "minitest-mpv-2")
    let r2 = mpv_initialize(mpv2)
    print("second instance init: \(r2)")
}

var report = ""
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    report += "===== 容器视图树 =====\n"
    func dump(_ v: NSView, _ indent: String) {
        let l = v.layer
        report += "\(indent)\(String(describing: type(of: v))) layer=\(l.map { String(describing: type(of: $0)) } ?? "nil") \(Int(v.frame.width))x\(Int(v.frame.height)) subs=\(v.subviews.count)\n"
        for s in v.subviews { dump(s, indent + "  ") }
    }
    dump(container, "")
    report += "===== 进程窗口（\(NSApp.windows.count)）=====\n"
    for w in NSApp.windows {
        report += "  \(String(describing: type(of: w))) vis=\(w.isVisible) '\(w.title)'\n"
    }
    print(report)
    exit(0)
}

// ===== 模拟 IINA：主队列 GCD 块内调用 mpv（经泵送包装）=====
if useQueueBlock {
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
        DispatchQueue.main.async {
            if !pumpedRead() { print("⚠️ queue-block read nil") }
        }
    }
}

// ===== 死锁压力：主线程高频读属性 =====
var stressCount = 0
var stressDead = false
let stressTimer: Timer? = noStress ? nil : Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
    guard pumpedRead() else {
        stressDead = true
        print("⚠️ stress read #\(stressCount) 返回 nil（可能卡死）")
        t.invalidate()
        return
    }
    stressCount += 1
    if stressCount % 25 == 0 { print("stress reads OK: \(stressCount)") }
}

app.run()
