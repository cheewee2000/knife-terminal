import AppKit
import CloudKit
import KnifeKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        AppModel.shared.theme.apply()
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { AppModel.shared.dispatchOpen(url.path) }
            else { AppModel.shared.dispatchOpen(url.absoluteString) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.checkSocket()
        if let wc = AppModel.shared.frontWindow(), let t = wc.activeTab, t.attention {
            t.attention = false
        }
    }

    // ─── CloudKit silent pushes (Input records from the phone) ───

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        if CKNotification(fromRemoteNotificationDictionary: userInfo) != nil {
            AppModel.shared.sync?.remotePushReceived()
        }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("knife: push registration failed: \(error)")
    }

    // ─── Menu ───

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Knife Terminal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "").target = updaterController
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Make Default Terminal…", action: #selector(setDefault), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Install Claude Code Alert Hooks…", action: #selector(installHooks), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "New Project from Folder…", action: #selector(adoptFolder), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Knife Terminal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Knife Terminal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Knife Terminal", action: nil, keyEquivalent: "").submenu = appMenu

        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "t").target = self
        shell.addItem(withTitle: "New Mini Terminal", action: #selector(newMini), keyEquivalent: "n").target = self
        shell.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w").target = self
        main.addItem(withTitle: "Shell", action: nil, keyEquivalent: "").submenu = shell

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(NSMenuItem.separator())
        // Tags are NSTextFinder.Action values: find() hands them to the chat pane's find bar when
        // chat is showing, else to SwiftTerm's TerminalView (it implements performTextFinderAction).
        let find = edit.addItem(withTitle: "Find…", action: #selector(find(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue; find.target = self
        let findNext = edit.addItem(withTitle: "Find Next", action: #selector(find(_:)), keyEquivalent: "g")
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue; findNext.target = self
        let findPrev = edit.addItem(withTitle: "Find Previous", action: #selector(find(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.tag = NSTextFinder.Action.previousMatch.rawValue; findPrev.target = self
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b").target = self
        view.addItem(withTitle: "Search Projects", action: #selector(focusSearch), keyEquivalent: "k").target = self
        let git = view.addItem(withTitle: "Toggle Git Panel", action: #selector(toggleGitPanel), keyEquivalent: "b")
        git.keyEquivalentModifierMask = [.command, .option]; git.target = self
        let chat = view.addItem(withTitle: "Toggle Chat View", action: #selector(toggleChatView), keyEquivalent: "c")
        chat.keyEquivalentModifierMask = [.command, .option]; chat.target = self
        view.addItem(.separator())
        for i in 1...9 {
            let item = view.addItem(withTitle: "Tab \(i)", action: #selector(jumpToTab(_:)), keyEquivalent: "\(i)")
            item.target = self; item.tag = i
        }
        view.addItem(.separator())
        let next = view.addItem(withTitle: "Next Tab", action: #selector(nextTab), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .shift]; next.target = self
        let prev = view.addItem(withTitle: "Previous Tab", action: #selector(prevTab), keyEquivalent: "[")
        prev.keyEquivalentModifierMask = [.command, .shift]; prev.target = self
        view.addItem(.separator())
        view.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private var front: KnifeWindowController? { AppModel.shared.frontWindow() }
    @objc private func adoptFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Make Project"
        panel.message = "git init + private GitHub repo (via gh), then open with Claude"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppModel.shared.adoptFolder(url.path)
    }

    @objc private func newTab() {
        if let wc = front { wc.addTab() } else { AppModel.shared.newWindow() }
    }
    @objc private func newMini() { AppModel.shared.newMiniTerm() }
    @objc private func closeTab() {
        // ⌘W in a mini popout closes the popout
        if let key = NSApp.keyWindow, let mini = AppModel.shared.minis.first(where: { $0.window == key }) {
            mini.close()
            return
        }
        guard let wc = front, let id = wc.activeId else { return }
        wc.closeTab(id)
    }
    @objc private func toggleSidebar() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "sidebarCollapsed"), forKey: "sidebarCollapsed")
    }
    @objc private func toggleGitPanel() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "gitPanel"), forKey: "gitPanel")
    }
    @objc private func toggleChatView() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "chatView"), forKey: "chatView")
    }
    @objc func find(_ sender: NSMenuItem) { // also the footer's find button
        if let wc = front, wc.chatShowing {
            NotificationCenter.default.post(name: .knifeChatFind, object: wc, userInfo: ["action": sender.tag])
        } else {
            NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
        }
    }
    @objc private func focusSearch() {
        NotificationCenter.default.post(name: .knifeFocusSearch, object: nil)
    }
    @objc private func jumpToTab(_ sender: NSMenuItem) {
        guard let wc = front else { return }
        let i = sender.tag - 1
        if i < wc.tabs.count { wc.activate(wc.tabs[i].id) }
    }
    @objc private func nextTab() { front?.cycle(1) }
    @objc private func prevTab() { front?.cycle(-1) }
    @objc private func setDefault() { DefaultTerminal.register() }
    @objc private func installHooks() { _ = HooksInstaller.install() }
}
