import UIKit

enum EntryMode: Int, CaseIterable {
    case alarm, reminder

    var title: String {
        self == .reminder ? "提醒事项" : "闹钟"
    }

    var symbol: String {
        self == .reminder ? "checklist" : "alarm"
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--inspect") {
            Task { await Diagnostics.inspect() }
            return true
        }
        #endif
        ReminderService.shared.start()
        return true
    }

    func application(
        _: UIApplication, configurationForConnecting session: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let tabs = UITabBarController()
        tabs.viewControllers = EntryMode.allCases.map { mode in
            let controller = EntryViewController(mode: mode)
            let navigation = UINavigationController(rootViewController: controller)
            navigation.tabBarItem = UITabBarItem(
                title: mode.title, image: UIImage(systemName: mode.symbol), tag: mode.rawValue
            )
            return navigation
        }
        let window = UIWindow(windowScene: scene)
        window.tintColor = .systemOrange
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window
    }
}

extension UIViewController {
    func showError(_ error: Error) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "未完成", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
