import AppKit

struct MenuState {
    var loggedIn = false
    var checking = true
    var displayName = ""
    var address = ""
    var port: UInt16 = 5333
    var serverError: String?
    var windowVisible = false
    var loadFailed = false
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    var state = MenuState()
    var onToggleWindow: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        applyIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    func refresh() {
        applyIcon()
    }

    private func applyIcon() {
        let symbol = state.loggedIn ? "envelope.fill" : "envelope.badge"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OWA Bridge")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip()
    }

    private func tooltip() -> String {
        if let serverError = state.serverError { return serverError }
        if state.loggedIn {
            return state.displayName.isEmpty ? "OWA Bridge 已登录" : "OWA Bridge 已登录 \(state.displayName)"
        }
        if state.checking { return "OWA Bridge 正在检查登录" }
        return "OWA Bridge 未登录"
    }

    private func rebuild() {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusTitle(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if state.loggedIn, !state.displayName.isEmpty || !state.address.isEmpty {
            let who = [state.displayName, state.address].filter { !$0.isEmpty }.joined(separator: " · ")
            let item = NSMenuItem(title: who, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let serverError = state.serverError {
            let item = NSMenuItem(title: serverError, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let endpoint = NSMenuItem(title: "接口：http://127.0.0.1:\(state.port)", action: nil, keyEquivalent: "")
            endpoint.isEnabled = false
            menu.addItem(endpoint)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(
            title: state.windowVisible ? "隐藏窗口" : "显示窗口",
            action: #selector(toggleWindow),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        let config = NSMenuItem(title: "打开配置目录", action: #selector(openConfig), keyEquivalent: "")
        config.target = self
        menu.addItem(config)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        applyIcon()
    }

    private func statusTitle() -> String {
        if state.loadFailed, !state.loggedIn { return "状态：页面加载失败" }
        if state.loggedIn { return "状态：已登录" }
        if state.checking { return "状态：正在检查登录…" }
        return "状态：未登录"
    }

    @objc private func toggleWindow() { onToggleWindow?() }
    @objc private func openConfig() { onOpenConfig?() }
    @objc private func quit() { onQuit?() }
}
