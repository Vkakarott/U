import Foundation

/// Decides what a new terminal runs.
protocol ShellLauncher {
    func launch(workingDirectory: String) -> ProcessLaunch
}

/// Starts the user's own shell as an interactive login shell, the way Terminal does.
///
/// The environment is built from the account record instead of inherited: under
/// launchd the daemon's environment is nearly empty, and the login shell's startup
/// files are what bring in the user's `PATH` and the rest of their setup.
struct LoginShellLauncher: ShellLauncher {
    /// Variables worth passing through when the daemon happens to have them.
    static let inheritedVariables = ["TMPDIR", "SSH_AUTH_SOCK", "LANG", "LC_ALL", "LC_CTYPE"]

    var daemonEnvironment: [String: String] = ProcessInfo.processInfo.environment

    func launch(workingDirectory: String) -> ProcessLaunch {
        let account = Self.account()
        var variables = [
            "HOME": account.home, "USER": account.name, "LOGNAME": account.name, "SHELL": account.shell,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color", "COLORTERM": "truecolor",
            "LANG": "en_US.UTF-8", "TERM_PROGRAM": "HubAgent",
        ]
        for name in Self.inheritedVariables {
            if let value = daemonEnvironment[name] { variables[name] = value }
        }
        return ProcessLaunch(
            executable: account.shell,
            environment: variables.map { "\($0.key)=\($0.value)" }.sorted(),
            processName: "-" + (account.shell as NSString).lastPathComponent,
            workingDirectory: workingDirectory)
    }

    private struct Account {
        var name: String
        var home: String
        var shell: String
    }

    private static func account() -> Account {
        guard let record = getpwuid(getuid()) else {
            return Account(name: NSUserName(), home: NSHomeDirectory(), shell: "/bin/zsh")
        }
        return Account(
            name: String(cString: record.pointee.pw_name), home: String(cString: record.pointee.pw_dir),
            shell: String(cString: record.pointee.pw_shell))
    }
}
