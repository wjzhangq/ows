import AppKit

public final class AppController: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?
    private var paths = BridgePaths.live()
    private var windowController: MailWindowController?
    private var statusController: StatusItemController?
    private var bridge: WebBridge?
    private var server: HTTPServer?
    private var api: APIHandler?
    private var menuState = MenuState()
    private var userHidWhileLoggedOut = false

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Keep Outlook WebView alive for the local bridge"
        )
        do {
            let prepared = try paths.prepare()
            BridgeLog.level = prepared.config.logLevel
            menuState.port = prepared.config.port
            let windowController = MailWindowController()
            let bridge = WebBridge(webView: windowController.webView, timeout: prepared.config.requestTimeoutSeconds)
            let api = APIHandler(token: prepared.token, config: prepared.config, backend: bridge)
            api.onSession = { [weak self] signal in
                DispatchQueue.main.async {
                    self?.apply(signal)
                }
            }
            self.windowController = windowController
            self.bridge = bridge
            self.api = api
            wire(windowController)
            let status = StatusItemController()
            status.state = menuState
            status.onToggleWindow = { [weak self] in self?.toggleWindow() }
            status.onOpenConfig = { [weak self] in self?.openConfig() }
            status.onQuit = { NSApp.terminate(nil) }
            statusController = status
            let server = HTTPServer { [weak self] request in
                guard let self, let api = self.api else {
                    return HTTPResponse.json(500, errorObject("extract_failed", "应用尚未就绪"))
                }
                return await api.handle(request)
            }
            server.onFailure = { [weak self] message in
                DispatchQueue.main.async {
                    self?.menuState.serverError = message
                    self?.publishMenu()
                }
            }
            try server.start(port: prepared.config.port)
            self.server = server
            windowController.loadOutlook()
            publishMenu()
        } catch {
            BridgeLog.error("启动失败")
            menuState.serverError = "启动失败"
            menuState.checking = false
            let status = StatusItemController()
            status.state = menuState
            status.onQuit = { NSApp.terminate(nil) }
            statusController = status
            status.refresh()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func wire(_ windowController: MailWindowController) {
        windowController.onLoginRequired = { [weak self] in
            self?.markLoggedOut(showWindow: true)
        }
        windowController.onMailPage = { [weak self] in
            self?.probeIdentity()
        }
        windowController.onLoadFailed = { [weak self] in
            guard let self else { return }
            self.menuState.loadFailed = true
            self.menuState.checking = false
            self.publishMenu()
            self.revealLoginIfNeeded()
        }
    }

    private func probeIdentity() {
        guard let api else { return }
        Task {
            let request = HTTPRequest(
                method: "GET",
                path: "/me",
                query: [:],
                headers: ["authorization": "Bearer \(api.token)"]
            )
            _ = await api.handle(request)
        }
    }

    private func apply(_ signal: SessionSignal) {
        switch signal {
        case .authenticated(let name, let address):
            menuState.loggedIn = true
            menuState.checking = false
            menuState.loadFailed = false
            if let name, !name.isEmpty { menuState.displayName = name }
            if let address, !address.isEmpty { menuState.address = address }
            userHidWhileLoggedOut = false
            if windowController?.userPinned != true {
                windowController?.park()
            }
        case .unauthenticated:
            markLoggedOut(showWindow: true)
        }
        publishMenu()
    }

    private func markLoggedOut(showWindow: Bool) {
        let wasLoggedIn = menuState.loggedIn
        menuState.loggedIn = false
        menuState.checking = false
        if wasLoggedIn {
            userHidWhileLoggedOut = false
            menuState.displayName = ""
            menuState.address = ""
        }
        if showWindow {
            revealLoginIfNeeded()
        }
        publishMenu()
    }

    private func revealLoginIfNeeded() {
        guard !userHidWhileLoggedOut else { return }
        windowController?.present(userInitiated: false)
        menuState.windowVisible = true
    }

    private func toggleWindow() {
        guard let windowController else { return }
        if windowController.isPresented {
            if !menuState.loggedIn {
                userHidWhileLoggedOut = true
            }
            windowController.park()
            menuState.windowVisible = false
        } else {
            userHidWhileLoggedOut = false
            windowController.present(userInitiated: true)
            menuState.windowVisible = true
        }
        publishMenu()
    }

    private func openConfig() {
        NSWorkspace.shared.open(paths.root)
    }

    private func publishMenu() {
        menuState.windowVisible = windowController?.isPresented ?? false
        statusController?.state = menuState
        statusController?.refresh()
    }
}
