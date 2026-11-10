import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - 状态

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var statusLineItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var autoRestoreItem: NSMenuItem!
    private var sudoersItem: NSMenuItem!
    private var resetItem: NSMenuItem!

    private var tickTimer: Timer?
    private var isBusy = false
    private var isOn = false              // 实际读到的状态
    private var desiredOn = false         // 用户希望的状态 —— 守护逻辑以它为准
    private var driftStrikes = 0          // 连续检测到「被外部关掉」的次数
    private var recoverTimes: [Date] = [] // 最近一小时内的自动恢复记录
    private var hasPasswordlessRule = false
    private var autoRestoreDeadline: Date?
    private var autoRestoreMinutes = 0
    private var isTerminating = false

    private let minutesOptions = [0, 30, 60, 120]

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("LidAwake 启动 · \(ProcessInfo.processInfo.operatingSystemVersionString)")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.image = symbol("laptopcomputer")
            button.setAccessibilityLabel("关盖运行")
            button.toolTip = "LidAwake · 关盖运行"
        }

        buildMenu()
        statusItem.menu = menu

        isOn = PowerManager.isSleepDisabled() ?? false
        desiredOn = isOn
        hasPasswordlessRule = PowerManager.hasPasswordlessRule()
        refreshUI()

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        showWelcomeIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
    }

    // MARK: - 菜单

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.removeAllItems()

        statusLineItem = NSMenuItem(title: "关盖运行：已关闭", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        menu.addItem(NSMenuItem.separator())

        toggleItem = NSMenuItem(title: "开启关盖运行", action: #selector(toggleAction), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        autoRestoreItem = NSMenuItem(title: "自动恢复", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for minutes in minutesOptions {
            let item = NSMenuItem(
                title: titleForAutoRestore(minutes),
                action: #selector(autoRestoreSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = minutes
            submenu.addItem(item)
        }
        autoRestoreItem.submenu = submenu
        menu.addItem(autoRestoreItem)

        menu.addItem(NSMenuItem.separator())

        sudoersItem = NSMenuItem(title: "安装免密切换规则…", action: #selector(sudoersAction), keyEquivalent: "")
        sudoersItem.target = self
        menu.addItem(sudoersItem)

        resetItem = NSMenuItem(title: "恢复默认电源设置", action: #selector(resetAction), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())

        let about = NSMenuItem(title: "关于与使用提示", action: #selector(aboutAction), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        hasPasswordlessRule = PowerManager.hasPasswordlessRule()
        if let actual = PowerManager.isSleepDisabled() {
            isOn = actual
        }
        refreshUI()
    }

    // MARK: - 刷新

    private func tick() {
        if let deadline = autoRestoreDeadline, deadline.timeIntervalSinceNow <= 0 {
            performAutoRestore()
            return
        }

        // 守护：用户希望开着，但系统标志被别人重置成了 0。
        // 读取失败（nil）时什么都不做，避免一次卡顿就误判成「被关掉」。
        if let actual = PowerManager.isSleepDisabled() {
            if desiredOn && !actual {
                driftStrikes += 1
                if driftStrikes >= 2 {          // 连续两次确认，排除瞬时抖动
                    driftStrikes = 0
                    reclaimSleepDisabled()
                    return
                }
            } else {
                driftStrikes = 0
                isOn = actual
            }
        }

        refreshUI()
    }

    /// 被外部重置后尝试静默抢回来；抢不回来就老实告诉用户。
    private func reclaimSleepDisabled() {
        guard !isBusy, !isTerminating else { return }

        // 一小时内恢复太多次，说明有别的程序在和我们拉锯，停手并提示。
        let now = Date()
        recoverTimes = recoverTimes.filter { now.timeIntervalSince($0) < 3600 }
        guard recoverTimes.count < 10 else {
            Log.error("关盖运行一小时内已被外部重置 \(recoverTimes.count) 次，停止自动恢复")
            desiredOn = false
            refreshUI()
            return
        }

        guard hasPasswordlessRule else {
            Log.error("关盖运行被外部关闭，但没有免密规则，无法静默恢复")
            refreshUI()
            return
        }

        recoverTimes.append(now)
        isBusy = true
        refreshUI()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let op = PowerManager.setSleepDisabledQuietly(true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if op.isOK {
                    Log.info("关盖运行被外部关闭，已自动恢复（近一小时第 \(self.recoverTimes.count) 次）")
                    self.isOn = true
                } else {
                    Log.error("自动恢复失败，停止守护")
                    self.desiredOn = false
                    self.recoverTimes.removeAll()
                }
                self.refreshUI()
            }
        }
    }

    private func refreshUI() {
        let drifted = desiredOn && !isOn

        if let button = statusItem.button {
            button.title = isOn ? " ON" : ""
            if drifted {
                button.image = symbol("exclamationmark.laptop") ?? symbol("laptopcomputer")
            } else {
                button.image = symbol(isOn ? "bolt.laptopcomputer" : "laptopcomputer") ?? symbol("laptopcomputer")
            }
        }

        var countdown = ""
        if isOn, let deadline = autoRestoreDeadline {
            countdown = " · \(formatRemaining(deadline.timeIntervalSinceNow)) 后恢复"
        }

        if drifted {
            statusLineItem.title = "关盖运行：被外部关掉了，正在恢复…"
            statusLineItem.image = symbol("exclamationmark.triangle.fill")
        } else {
            statusLineItem.title = isOn ? "关盖运行：已开启\(countdown)" : "关盖运行：已关闭"
            statusLineItem.image = symbol(isOn ? "checkmark.circle.fill" : "circle")
        }

        toggleItem.title = isBusy ? "处理中…" : (isOn ? "关闭关盖运行" : "开启关盖运行")
        toggleItem.isEnabled = !isBusy

        autoRestoreItem.isEnabled = !isBusy
        autoRestoreItem.title = isOn ? "自动恢复" : "自动恢复（开启后生效）"
        autoRestoreItem.submenu?.items.forEach { item in
            let minutes = item.representedObject as? Int ?? 0
            item.state = (minutes == autoRestoreMinutes) ? .on : .off
            item.isEnabled = isOn && !isBusy
        }

        resetItem.isEnabled = isOn && !isBusy

        sudoersItem.title = hasPasswordlessRule
            ? "免密切换：已启用 ✓（点按管理）"
            : "安装免密切换规则…"
        sudoersItem.isEnabled = !isBusy
    }

    // MARK: - 动作

    @objc private func toggleAction() {
        setEnabled(!isOn)
    }

    @objc private func autoRestoreSelected(_ sender: NSMenuItem) {
        autoRestoreMinutes = sender.representedObject as? Int ?? 0
        if isOn {
            autoRestoreDeadline = autoRestoreMinutes > 0
                ? Date().addingTimeInterval(TimeInterval(autoRestoreMinutes * 60))
                : nil
        }
        Log.info("自动恢复设为 \(autoRestoreMinutes == 0 ? "关" : "\(autoRestoreMinutes) 分钟")")
        refreshUI()
    }

    @objc private func resetAction() {
        setEnabled(false)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    @objc private func aboutAction() {
        activate()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "LidAwake · 关盖不休眠"
        alert.informativeText = """
        版本 \(version)（Build \(build)）

        原理：调用系统的 `pmset -a disablesleep` 电源标志。这是 macOS 上真正能挡住「合盖睡眠」的开关——`caffeinate` 做不到这一点。

        · 开启后合盖，机器会继续运行（下载、编译、跑任务）。
        · 注意散热：合盖时热量积在机身里，MacBook Air 这类无风扇机型尤其要留意，别长时间放在床上、沙发或包里。
        · 建议用「自动恢复」设个时间，免得忘记。

        免密规则位置：/etc/sudoers.d/lidawake
        日志：~/Library/Logs/LidAwake.log
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    // MARK: - 切换核心

    private func setEnabled(_ on: Bool) {
        guard !isBusy else { return }
        isBusy = true
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = PowerManager.setSleepDisabled(on)

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false

                switch result {
                case .ok:
                    Log.info("关盖运行 → \(on ? "开启" : "关闭")")
                    self.desiredOn = on
                    self.driftStrikes = 0
                    self.recoverTimes.removeAll()
                    if on {
                        self.autoRestoreDeadline = self.autoRestoreMinutes > 0
                            ? Date().addingTimeInterval(TimeInterval(self.autoRestoreMinutes * 60))
                            : nil
                    } else {
                        self.autoRestoreDeadline = nil
                    }
                    self.isOn = PowerManager.isSleepDisabled() ?? on
                    self.refreshUI()

                case .cancelled:
                    Log.info("用户取消了管理员授权")
                    self.refreshUI()

                case .failed(let message):
                    Log.error("切换失败：\(message)")
                    self.refreshUI()
                    self.presentError("没能切换关盖运行", message)
                }
            }
        }
    }

    private func performAutoRestore() {
        autoRestoreDeadline = nil
        Log.info("自动恢复触发：恢复默认电源设置")
        NSSound(named: "Glass")?.play()
        setEnabled(false)
    }

    // MARK: - 免密规则

    @objc private func sudoersAction() {
        isBusy = true
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasRule = PowerManager.hasPasswordlessRule()

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.hasPasswordlessRule = hasRule
                self.refreshUI()

                if hasRule {
                    self.confirmRemoveRule()
                } else {
                    self.confirmInstallRule()
                }
            }
        }
    }

    private func confirmInstallRule() {
        activate()
        let alert = NSAlert()
        alert.messageText = "安装免密切换规则"
        alert.informativeText = """
        安装后，开关关盖运行时不再弹出管理员密码框。

        改动只有一处：在 `/etc/sudoers.d/lidawake` 里授权两条精确命令
        （`pmset -a disablesleep 0` 和 `1`），不涉及其他权限。随时可以移除。
        """
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runRuleChange(install: true)
    }

    private func confirmRemoveRule() {
        activate()
        let alert = NSAlert()
        alert.messageText = "免密切换已启用"
        alert.informativeText = "当前切换不需要输入密码。要移除这条规则、恢复成每次都要授权吗？"
        alert.addButton(withTitle: "保留")
        alert.addButton(withTitle: "移除规则")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        runRuleChange(install: false)
    }

    private func runRuleChange(install: Bool) {
        isBusy = true
        refreshUI()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = install
                ? PowerManager.installPasswordlessRule()
                : PowerManager.removePasswordlessRule()

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                if result.isOK {
                    self.hasPasswordlessRule = install
                }
                self.refreshUI()

                switch result {
                case .ok:
                    Log.info(install ? "免密规则已安装" : "免密规则已移除")
                    self.toast(
                        install ? "免密切换已启用" : "免密规则已移除",
                        install ? "之后开关关盖运行不会再弹密码框。" : "之后每次切换都会请求管理员授权。"
                    )
                case .cancelled:
                    Log.info("用户取消了规则变更授权")
                case .failed(let message):
                    Log.error("规则变更失败：\(message)")
                    self.presentError(install ? "安装失败" : "移除失败", message)
                }
            }
        }
    }

    // MARK: - 退出

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }
        if isBusy {
            presentError("还在处理中", "有一个操作没有完成，稍等一下再退出吧。")
            return .terminateCancel
        }
        guard PowerManager.isSleepDisabled() == true else { return .terminateNow }

        activate()
        let alert = NSAlert()
        alert.messageText = "关盖运行还开着"
        alert.informativeText = """
        现在退出的话，电脑在合盖后仍会继续运行。
        建议先把电源设置恢复成默认。
        """
        alert.addButton(withTitle: "恢复并退出")
        alert.addButton(withTitle: "直接退出")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            isTerminating = true
            isBusy = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = PowerManager.restoreDefault()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isBusy = false
                    self.isTerminating = false
                    if result.isOK {
                        Log.info("退出前已恢复默认电源设置")
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } else {
                        Log.error("退出前恢复失败")
                        self.presentError("恢复失败", "电源设置没能恢复。可以再试一次，或在「系统设置 › 电池」里确认。")
                        NSApp.reply(toApplicationShouldTerminate: false)
                    }
                }
            }
            return .terminateLater

        case .alertSecondButtonReturn:
            Log.info("用户选择保留设置直接退出")
            return .terminateNow

        default:
            return .terminateCancel
        }
    }

    // MARK: - 小工具

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func titleForAutoRestore(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "不自动恢复"
        case 30: return "30 分钟后恢复"
        case 60: return "1 小时后恢复"
        case 120: return "2 小时后恢复"
        default: return "\(minutes) 分钟后恢复"
        }
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total >= 3600 {
            let hours = total / 3600
            let mins = (total % 3600) / 60
            return mins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(mins) 分"
        }
        let mins = max(1, (total + 59) / 60)
        return "\(mins) 分钟"
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentError(_ title: String, _ message: String) {
        activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func toast(_ title: String, _ message: String) {
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showWelcomeIfNeeded() {
        let key = "didShowWelcome.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.activate()
            let alert = NSAlert()
            alert.messageText = "合盖不休眠，已经装好了"
            alert.informativeText = """
            我住在屏幕右上角的菜单栏里，图标是一台小电脑。

            点它 → 「开启关盖运行」，合上盖子机器也会继续跑。
            建议顺手开「自动恢复」，免得忘记散热这回事。

            想免得每次输密码，可以点「安装免密切换规则」。
            """
            alert.addButton(withTitle: "开始使用")
            alert.runModal()
        }
    }
}
