import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        let controller = MainViewController()
        NSApp.mainMenu = makeMainMenu(fontTarget: controller)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = DebugInstance.tag.map { "\(appName) · \($0)" } ?? appName
        window.contentMinSize = NSSize(width: 720, height: 400)
        window.contentViewController = controller
        window.addTitlebarAccessoryViewController(controller.titlebarAccessory)
        window.isReleasedWhenClosed = false
        window.center()
        // 记住窗口位置 / 尺寸 (常用最大化).
        window.setFrameAutosaveName("main")
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

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "jj-calendar"
    }

    /// 无 nib 时系统不生成菜单栏; 最小菜单保证 ⌘Q / ⌘W / ⌘M 可用.
    private func makeMainMenu(fontTarget: MainViewController) -> NSMenu {
        let appMenu = NSMenu()
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
