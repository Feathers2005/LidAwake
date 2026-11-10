import Foundation

/// 一次电源操作的结果。
enum PowerOp {
    case ok
    case cancelled          // 用户取消了管理员授权
    case failed(String)     // 带可读原因

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

/// 关盖运行的真正开关：`pmset -a disablesleep 0|1`。
///
/// 注意：`caffeinate` 只能阻止「闲置睡眠」，挡不住合盖触发的 clamshell sleep；
/// 真正让合盖后系统继续运行的是 SleepDisabled 这个电源标志。
enum PowerManager {

    static let pmset     = "/usr/bin/pmset"
    static let sudo      = "/usr/bin/sudo"
    static let osascript = "/usr/bin/osascript"
    static let bash      = "/bin/bash"

    static let sudoersTarget = "/etc/sudoers.d/lidawake"

    // MARK: - 读状态（不需要 root）

    /// 当前是否处于「关盖也不睡」的状态。
    /// 读取失败时返回 nil —— 调用方要把它和「明确关闭」区分开，否则一次卡顿就会被误判成被关。
    static func isSleepDisabled() -> Bool? {
        let r = Shell.run(pmset, ["-g"], timeout: 10)
        guard r.ok else { return nil }
        for line in r.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return nil
    }

    // MARK: - 切换

    /// 开关关盖运行。先尝试免密，失败再走系统管理员授权弹窗。
    static func setSleepDisabled(_ disabled: Bool) -> PowerOp {
        let value = disabled ? "1" : "0"

        // 1) 已经装过免密规则 —— 静默切换
        let silent = Shell.run(sudo, ["-n", pmset, "-a", "disablesleep", value], timeout: 20)
        if silent.ok { return .ok }

        // 2) 走管理员授权
        return privilegedShell("\(pmset) -a disablesleep \(value)")
    }

    /// 恢复系统默认（允许合盖睡眠）。
    static func restoreDefault() -> PowerOp {
        setSleepDisabled(false)
    }

    /// 只走免密切换，绝不弹授权窗 —— 供后台守护使用。
    /// 没装免密规则时直接返回失败，让上层决定要不要提示用户。
    static func setSleepDisabledQuietly(_ disabled: Bool) -> PowerOp {
        let value = disabled ? "1" : "0"
        let r = Shell.run(sudo, ["-n", pmset, "-a", "disablesleep", value], timeout: 20)
        if r.ok { return .ok }
        let text = r.message
        if text.localizedCaseInsensitiveContains("a password is required")
            || text.localizedCaseInsensitiveContains("a terminal is required") {
            return .failed("没有免密规则，无法静默恢复。")
        }
        return .failed(text.isEmpty ? "静默切换失败（退出码 \(r.status)）" : text)
    }

    // MARK: - 免密规则

    /// 是否已经安装了免密规则。
    static func hasPasswordlessRule() -> Bool {
        let probe = Shell.run(sudo, ["-n", "-l", pmset, "-a", "disablesleep", "1"], timeout: 10)
        if probe.ok { return true }
        let all = Shell.run(sudo, ["-n", "-l"], timeout: 10)
        return all.ok && all.out.contains("disablesleep")
    }

    /// 安装免密规则：只授权两条精确命令，随时可删。
    static func installPasswordlessRule() -> PowerOp {
        runPrivilegedScript(installScript, name: "install-sudoers") { ok in
            ok && hasPasswordlessRule()
        }
    }

    /// 移除免密规则。
    static func removePasswordlessRule() -> PowerOp {
        runPrivilegedScript(uninstallScript, name: "remove-sudoers") { ok in
            ok && !hasPasswordlessRule()
        }
    }

    // MARK: - 提权执行

    /// 用 AppleScript 的 `with administrator privileges` 跑一条 shell 命令。
    private static func privilegedShell(_ command: String) -> PowerOp {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let r = Shell.run(osascript, ["-e", script], timeout: 300)
        if r.ok { return .ok }

        let text = r.message
        if text.localizedCaseInsensitiveContains("User canceled")
            || text.localizedCaseInsensitiveContains("user cancelled")
            || text.contains("(-128)") {
            return .cancelled
        }
        if text.localizedCaseInsensitiveContains("not permitted")
            || text.localizedCaseInsensitiveContains("not allowed") {
            return .failed("系统拒绝了这次修改，可能有 MDM 描述文件或安全策略在限制。")
        }
        return .failed(text.isEmpty ? "未知错误（退出码 \(r.status)）" : text)
    }

    /// 把一段 bash 脚本写到 Application Support，再用管理员权限执行。
    /// 这样避免在 AppleScript 字符串里做多层转义。
    private static func runPrivilegedScript(
        _ body: String,
        name: String,
        verify: (Bool) -> Bool
    ) -> PowerOp {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LidAwake", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failed("无法创建临时目录：\(error.localizedDescription)")
        }

        let scriptURL = dir.appendingPathComponent("\(name).sh")
        let header = "#!/bin/bash\nset -euo pipefail\n"
        do {
            try (header + body).write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            return .failed("无法写入临时脚本：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: scriptURL) }

        let op = privilegedShell("\(bash) \(Shell.quote(scriptURL.path))")
        guard op.isOK else { return op }

        // 给 sudo / 目录缓存一点时间，再复核实际效果。
        for _ in 0..<10 {
            if verify(true) { return .ok }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return .failed("规则已写入，但校验没有通过。可以稍后重试，或检查 /etc/sudoers.d 是否被管理员策略禁用。")
    }

    // MARK: - 脚本正文

    private static let installScript = """
    TARGET="\(sudoersTarget)"
    TMP="$(mktemp /tmp/lidawake-sudoers.XXXXXX)"
    trap 'rm -f "$TMP"' EXIT

    cat > "$TMP" <<'RULES'
    # Managed by LidAwake — 免密切换「关盖运行」
    # 删除本文件即可撤销：sudo rm -f /etc/sudoers.d/lidawake
    %admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
    RULES

    chown root:wheel "$TMP"
    chmod 0440 "$TMP"
    /usr/sbin/visudo -c -f "$TMP" >/dev/null
    install -m 0440 -o root -g wheel "$TMP" "$TARGET"
    echo OK
    """

    private static let uninstallScript = """
    rm -f "\(sudoersTarget)"
    echo OK
    """
}
