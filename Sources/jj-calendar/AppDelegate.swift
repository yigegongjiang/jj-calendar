import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = DebugInstance.tag.map { "\(appName) · \($0)" } ?? appName
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.contentViewController = MainViewController()
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "jj-calendar"
    }

    /// 无 nib 时系统不生成菜单栏; 最小菜单保证 ⌘Q / ⌘W / ⌘M 可用.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        let quit = #selector(NSApplication.terminate(_:))
        appMenu.addItem(withTitle: "Quit \(appName)", action: quit, keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let minimize = #selector(NSWindow.performMiniaturize(_:))
        windowMenu.addItem(withTitle: "Minimize", action: minimize, keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
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
