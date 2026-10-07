import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var frameObservers: [NSObjectProtocol] = []
    private var pendingFrameSave: Task<Void, Never>?

    func applicationDidFinishLaunching(_: Notification) {
        ConfigStore.load()
        let controller = MainViewController()
        NSApp.mainMenu = makeMainMenu(fontTarget: controller)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = DebugInstance.tag.map { "\(appName) · \($0)" } ?? appName
        window.subtitle = ConfigStore.warnings
        window.contentMinSize = NSSize(width: 720, height: 400)
        window.contentViewController = controller
        window.addTitlebarAccessoryViewController(controller.titlebarAccessory)
        window.isReleasedWhenClosed = false
        restoreFrame(window)
        self.window = window
        // Debug 实例 (debug.sh 后台启动) 置于所有窗口之后且不激活: 不遮挡 / 不打断正在使用的 App.
        if DebugInstance.tag == nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderBack(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// 窗口位置 / 尺寸 (常用最大化) 存 state.json; 已不在任何屏幕内则居中.
    private func restoreFrame(_ window: NSWindow) {
        if let saved = ConfigStore.state.window {
            let frame = NSRect(x: saved.minX, y: saved.minY, width: saved.width, height: saved.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
        } else {
            window.center()
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFrameSave() }
            })
        }
    }

    /// 拖动 / 缩放过程中连续触发, 停止 0.5 秒后再写入.
    private func scheduleFrameSave() {
        pendingFrameSave?.cancel()
        pendingFrameSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let frame = self?.window?.frame else { return }
            ConfigStore.update {
                $0.window = WindowFrame(minX: frame.minX, minY: frame.minY, width: frame.width, height: frame.height)
            }
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "jj-calendar"
    }

    /// 配置即文件: Finder 打开配置目录, 手工编辑 config.jsonc. Debug 实例不激活 Finder, 不打断人类.
    @objc
    private func openConfigFolder(_: Any?) {
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = DebugInstance.tag == nil
        NSWorkspace.shared.open(ConfigStore.directory, configuration: configuration)
    }

    /// 无 nib 时系统不生成菜单栏; 最小菜单保证 ⌘Q / ⌘W / ⌘M 可用.
    private func makeMainMenu(fontTarget: MainViewController) -> NSMenu {
        let appMenu = NSMenu()
        let openConfig = #selector(openConfigFolder(_:))
        let settings = appMenu.addItem(withTitle: "Settings…", action: openConfig, keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let quit = #selector(NSApplication.terminate(_:))
        appMenu.addItem(withTitle: "Quit \(appName)", action: quit, keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let minimize = #selector(NSWindow.performMiniaturize(_:))
        windowMenu.addItem(withTitle: "Minimize", action: minimize, keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        // 字号: 直接指向 controller, 不依赖 key window 响应链 (后台 AX 调用同样可用).
        let viewMenu = NSMenu(title: "View")
        let larger = #selector(MainViewController.increaseFontSize(_:))
        let smaller = #selector(MainViewController.decreaseFontSize(_:))
        let reset = #selector(MainViewController.resetFontSize(_:))
        viewMenu.addItem(withTitle: "放大字号", action: larger, keyEquivalent: "+")
        // 隐藏项: 不按 Shift 的 ⌘= 同样放大.
        let largerAlias = viewMenu.addItem(withTitle: "放大字号", action: larger, keyEquivalent: "=")
        largerAlias.isHidden = true
        largerAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(withTitle: "缩小字号", action: smaller, keyEquivalent: "-")
        viewMenu.addItem(withTitle: "默认字号", action: reset, keyEquivalent: "0")
        viewMenu.items.forEach { $0.target = fontTarget }

        let mainMenu = NSMenu()
        for submenu in [appMenu, viewMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}

/// `scripts/debug.sh` 传入的 worktree 名, 区分并行运行的多个 Debug 实例; Release 恒为 nil.
enum DebugInstance {
    static let tag: String? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["JJCAL_DEBUG_TAG"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        nil
        #endif
    }()
}
