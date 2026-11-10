// MultiClaude — several Claude Desktop apps side by side, one account each.
//
// One binary, two roles (the MultiClaudeRole key of the bundle's Info.plist):
//
//   launcher  /Applications/<Claude B>.app (tinted icon). Starts the router, then the account's own
//             untouched copy of Claude.app with --user-data-dir, and quits as soon as it is up.
//
//   router    ~/Library/Application Support/MultiClaude/Claude Router.app, no interface. Permanent when
//             started by the login agent (--agent, see install.sh), otherwise alive while a copy runs.
//             It finds the accounts on disk at every event, so adding one needs nothing here. It
//             - receives every claude:// link (sign-in returns, MCP OAuth returns, deep links) and
//               hands it to the right instance;
//             - takes the claude:// scheme back each time a Claude starts (the app re-claims it);
//             - catches a copy started WITHOUT --user-data-dir (a Dock click on its tile, Squirrel's
//               relaunch after an update): it would open the first account's profile, so the router
//               stops it and starts it properly;
//             - puts the tinted icon back on a copy after an update wiped it.
//
// Command line: --status, --explain <link>, --set-icon <icns> <bundle>, --has-icon <bundle>.

import AppKit
import Foundation

let home = NSHomeDirectory()
let supportDir = "\(home)/Library/Application Support"
let root = "\(supportDir)/MultiClaude"
let claudeBundleId = "com.anthropic.claudefordesktop"
let mainApp = URL(fileURLWithPath: "/Applications/Claude.app")
let mainBinary = mainApp.path + "/Contents/MacOS/Claude"
let mainDataDir = "\(supportDir)/Claude"
let routerApp = URL(fileURLWithPath: "\(root)/Claude Router.app")
let schemes = ["claude", "msauth.com.anthropic.claudefordesktop"]
let desktopLog = "\(home)/Library/Logs/Claude/main.log"
let logPath = "\(home)/Library/Logs/MultiClaude.log"
let graceAfterQuit: TimeInterval = 120   // a non-agent router stays this long with no copy alive (update relaunch)
let mcpSignInMaxAge = TimeInterval(ProcessInfo.processInfo.environment["MULTICLAUDE_MCP_MAX_AGE"] ?? "") ?? 900

let info = Bundle.main.infoDictionary ?? [:]
let role = info["MultiClaudeRole"] as? String ?? "tool"
let agentMode = CommandLine.arguments.contains("--agent")   // started by launchd: never quits on its own

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) [\(role)] \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

// MARK: - Accounts (one copy of Claude.app per extra account)

struct Profile {
    let name: String                                   // "Claude B"
    var app: String { "\(root)/\(name)/Claude.app" }
    var binary: String { app + "/Contents/MacOS/Claude" }
    var dataDir: String { "\(supportDir)/\(name)" }
    var icon: String { "\(root)/\(name)/icon.icns" }
}

func profiles() -> [Profile] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
        .filter { FileManager.default.fileExists(atPath: "\(root)/\($0)/Claude.app/Contents/Info.plist") }
        .map { Profile(name: $0) }
}

// MARK: - Custom icon (an "Icon\r" file at the bundle root: outside the code signature, which stays valid)

func hasCustomIcon(_ bundle: String) -> Bool { FileManager.default.fileExists(atPath: bundle + "/Icon\r") }

/// NSWorkspace reports success even when macOS silently refuses, so trust the file, not the return value.
@discardableResult
func setCustomIcon(_ icns: String, on bundle: String) -> Bool {
    guard let img = NSImage(contentsOfFile: icns) else { return false }
    return NSWorkspace.shared.setIcon(img, forFile: bundle, options: []) && hasCustomIcon(bundle)
}

/// Puts the icon back on a copy that lost it (a Claude update replaces the whole bundle). macOS only lets
/// an app modify another one when it is allowed under System Settings > Privacy & Security > App Management.
var iconRefused = Set<String>()
func ensureIcon(_ p: Profile) {
    guard FileManager.default.fileExists(atPath: p.icon), !hasCustomIcon(p.app) else { iconRefused.remove(p.name); return }
    if setCustomIcon(p.icon, on: p.app) { iconRefused.remove(p.name); log("icon restored on the \(p.name) copy") }
    else if iconRefused.insert(p.name).inserted {
        log("macOS refused to put the icon back on the \(p.name) copy: allow Claude Router under System Settings > Privacy & Security > App Management, or run install.sh again")
    }
}

// MARK: - Processes

/// Arguments of a process through sysctl (no subprocess).
func procArgs(_ pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
    let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24
    var parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
    guard !parts.isEmpty else { return [] }
    parts.removeFirst()                       // executable path
    parts = parts.drop { $0.isEmpty }.map { $0 } // padding
    return Array(parts.prefix(max(argc, 0)))
}

struct Instance {
    let pid: pid_t
    let binary: String
    let dataDir: String        // effective data folder
    let bare: Bool             // started without --user-data-dir
    var label: String { binary == mainBinary && bare ? "Claude" : URL(fileURLWithPath: dataDir).lastPathComponent }
}

/// Running Claude instances (Claude.app and every copy): main processes only.
func listInstances() -> [Instance] {
    let binaries = [mainBinary] + profiles().map { $0.binary }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axwwo", "pid=,args="]
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { return [] }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    var result: [Instance] = []
    for rawLine in out.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let space = line.firstIndex(of: " "), let pid = pid_t(line[..<space]) else { continue }
        let args = line[space...].trimmingCharacters(in: .whitespaces)
        guard let bin = binaries.first(where: { args == $0 || args.hasPrefix($0 + " ") }) else { continue }
        var dd: String? = nil
        if let r = args.range(of: "--user-data-dir=") {
            dd = String(args[r.upperBound...]).components(separatedBy: " --").first?.trimmingCharacters(in: .whitespaces)
        }
        result.append(Instance(pid: pid, binary: bin, dataDir: dd ?? mainDataDir, bare: dd == nil))
    }
    return result
}

func isCopy(_ i: Instance) -> Bool { i.binary != mainBinary }

/// The instance owning the frontmost normal window on the current screen.
func frontmostByWindows(_ instances: [Instance]) -> Instance? {
    let pids = Set(instances.map { $0.pid })
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in windows {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else { continue }
        if (w[kCGWindowLayer as String] as? Int) == 0 { return instances.first { $0.pid == pid } }
    }
    return nil
}

// MARK: - Launching

@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// posix_spawn with responsibility disclaimed: macOS attributes permissions to Claude, not to us.
func spawnDisclaimed(_ path: String, _ args: [String]) -> pid_t {
    var attrs: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }
    _ = responsibility_spawnattrs_setdisclaim(&attrs, 1)
    posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID))
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, nil, &attrs, argv, environ)
    return rc == 0 ? pid : 0
}

func activate(_ pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps]) }

/// Starts Claude.app (profile nil) or an account's copy on its data folder.
func launchClaude(_ profile: Profile?, completion: @escaping (pid_t) -> Void) {
    let pid = profile.map { spawnDisclaimed($0.binary, ["--user-data-dir=\($0.dataDir)"]) } ?? spawnDisclaimed(mainBinary, [])
    if pid == 0 { log("starting \(profile?.name ?? "Claude") failed: posix_spawn errno \(errno)"); completion(0); return }
    log("started \(profile?.name ?? "Claude") pid \(pid)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { activate(pid); completion(pid) }
}

func runningCopy(of p: Profile) -> Instance? { listInstances().first { $0.binary == p.binary && !$0.bare && $0.dataDir == p.dataDir } }

// MARK: - Links

func sendURL(_ url: String, to pid: pid_t) -> Bool {
    let target = NSAppleEventDescriptor(processIdentifier: pid)
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                       targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(NSAppleEventDescriptor(string: url), forKeyword: AEKeyword(keyDirectObject))
    do { _ = try event.sendEvent(options: [.noReply], timeout: 5); return true }
    catch { log("sending the link to pid \(pid) failed: \(error)"); return false }
}

func schemeOwner(_ scheme: String) -> String? { LSCopyDefaultHandlerForURLScheme(scheme as CFString)?.takeRetainedValue() as String? }

/// Only rewrites the handler when it changed (every Claude start re-claims it).
func claimSchemes() {
    guard let me = Bundle.main.bundleIdentifier else { return }
    for s in schemes {
        let current = schemeOwner(s)
        if current?.lowercased() != me.lowercased() {
            LSSetDefaultHandlerForURLScheme(s as CFString, me as CFString)
            log("took \(s):// back (was \(current ?? "nobody"))")
        }
    }
}

/// A link without its secrets (code, state…), for the log.
func describe(_ url: String) -> String {
    guard let c = URLComponents(string: url) else { return "claude://…" }
    return "\(c.scheme ?? "?")://\(c.host ?? "")\(c.path)" + ((c.queryItems?.isEmpty ?? true) ? "" : "?…")
}

/// The instance that started the most recent MCP sign-in. Claude Desktop writes
/// `mcpAuthenticate…: sessionId="local_…"` to its log (shared by all instances) when a Code session opens
/// the browser, and that session's file only exists in the data folder of its own instance.
func mcpSignInOwner(_ instances: [Instance]) -> Instance? {
    guard let h = FileHandle(forReadingAtPath: desktopLog) else { return nil }
    defer { h.closeFile() }
    let size = h.seekToEndOfFile()
    h.seek(toFileOffset: size > 600_000 ? size - 600_000 : 0)
    let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    guard let re = try? NSRegularExpression(pattern: #"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) .*mcpAuthenticate\w*: sessionId="?(local_[0-9a-fA-F-]+)"#, options: [.anchorsMatchLines]) else { return nil }
    let ns = text as NSString
    guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
    let fmt = DateFormatter(); fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    guard let when = fmt.date(from: ns.substring(with: m.range(at: 1))), Date().timeIntervalSince(when) < mcpSignInMaxAge else { return nil }
    let session = ns.substring(with: m.range(at: 2))
    let fm = FileManager.default
    return instances.first { inst in
        let base = inst.dataDir + "/claude-code-sessions"
        for acct in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
            for org in (try? fm.contentsOfDirectory(atPath: "\(base)/\(acct)")) ?? [] where fm.fileExists(atPath: "\(base)/\(acct)/\(org)/\(session).json") { return true }
        }
        return false
    }
}

// MARK: - Router

final class Router: NSObject, NSApplicationDelegate {
    var lastActive: [pid_t: Date] = [:]      // when each Claude instance was last brought to the front
    var handled = Set<pid_t>()               // bare launches already dealt with
    var relaunching = Set<String>()
    var idleSince = Date()

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:with:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let me = Bundle.main.bundleIdentifier ?? ""
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: me).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            if agentMode { others.forEach { $0.forceTerminate() } }   // the login agent is the reference router
            else {
                // a router is already running: macOS gave it (or will give it) the link
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }; return
            }
        }
        log(agentMode ? "router up (login agent, permanent)" : "router up")
        claimSchemes()
        profiles().forEach(ensureIcon)
        if let f = frontmostByWindows(listInstances()) { lastActive[f.pid] = Date() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == claudeBundleId else { return }
            self.lastActive[app.processIdentifier] = Date()
        }
        for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == claudeBundleId else { return }
                self.claudeLaunched(app)
            }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in self.tick() }
    }

    /// A Claude is starting: it will re-claim claude://, and a bare copy has to be stopped.
    func claudeLaunched(_ app: NSRunningApplication) {
        for delay in [2.0, 6.0, 12.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { claimSchemes() } }
        guard let path = app.bundleURL?.standardizedFileURL.path, let p = profiles().first(where: { URL(fileURLWithPath: $0.app).standardizedFileURL.path == path }) else { return }
        guardBareLaunch(pid: app.processIdentifier, profile: p, attempt: 0)
    }

    func guardBareLaunch(pid: pid_t, profile p: Profile, attempt: Int) {
        if handled.contains(pid) { return }
        let args = procArgs(pid)
        if args.isEmpty && attempt < 20 && kill(pid, 0) == 0 {   // not exec'd yet: look again right away
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.guardBareLaunch(pid: pid, profile: p, attempt: attempt + 1) }; return
        }
        handled.insert(pid)
        if args.contains(where: { $0.hasPrefix("--user-data-dir=") }) { return }
        kill(pid, SIGKILL)
        log("\(p.name) copy started without its data folder (Dock click or update, pid \(pid)): stopped, starting \(p.name) properly")
        guard !relaunching.contains(p.name) else { return }
        relaunching.insert(p.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            ensureIcon(p)
            if let running = runningCopy(of: p) { activate(running.pid); self.relaunching.remove(p.name) }
            else { launchClaude(p) { _ in self.relaunching.remove(p.name) } }
        }
    }

    func tick() {
        claimSchemes()
        profiles().forEach(ensureIcon)
        let instances = listInstances()
        lastActive = lastActive.filter { pid, _ in instances.contains { $0.pid == pid } }
        if agentMode || instances.contains(where: isCopy) || !relaunching.isEmpty { idleSince = Date(); return }
        if Date().timeIntervalSince(idleSince) > graceAfterQuit { log("no copy running, router quitting"); NSApp.terminate(nil) }
    }

    /// Who gets a link: the recipients and the reason (logged).
    func targets(for url: String, among instances: [Instance]) -> ([Instance], String) {
        if instances.count == 1 { return (instances, "only instance") }
        let c = URLComponents(string: url)
        if c?.host == "login" && c?.path == "/google-auth" {
            // Every instance ignores a code that does not answer a sign-in it started.
            return (instances, "sign-in return: offered to every instance, only the one that started it takes it")
        }
        if c?.host == "claude.ai" && c?.path == "/mcp-auth-callback/sdk", let owner = mcpSignInOwner(instances) {
            return ([owner], "MCP sign-in started by this instance (desktop log)")
        }
        if let pid = lastActive.max(by: { $0.value < $1.value })?.key, let i = instances.first(where: { $0.pid == pid }) {
            return ([i], "last active Claude")
        }
        if let f = frontmostByWindows(instances) { return ([f], "frontmost window") }
        return ([instances.first { $0.binary == mainBinary } ?? instances[0]], "default")
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        idleSince = Date()
        guard let url = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        let instances = listInstances().filter { !($0.bare && isCopy($0)) }
        guard !instances.isEmpty else {
            log("\(describe(url)): no instance running, opening Claude.app with the link")
            if let u = URL(string: url) { NSWorkspace.shared.open([u], withApplicationAt: mainApp, configuration: NSWorkspace.OpenConfiguration()) { _, _ in } }
            return
        }
        let (dest, why) = targets(for: url, among: instances)
        log("\(describe(url)) -> \(dest.map { "\($0.label) (pid \($0.pid))" }.joined(separator: ", ")) — \(why)")
        for d in dest { _ = sendURL(url, to: d.pid) }
        let front = dest.count == 1 ? dest[0] : (dest.max { (lastActive[$0.pid] ?? .distantPast) < (lastActive[$1.pid] ?? .distantPast) } ?? dest[0])
        activate(front.pid)
    }
}

// MARK: - Launcher

final class Launcher: NSObject, NSApplicationDelegate {
    let profile = Profile(name: info["MultiClaudeProfile"] as? String ?? "Claude B")

    func applicationDidFinishLaunching(_ n: Notification) {
        let me = Bundle.main.bundleIdentifier ?? ""
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { exitSoon(0.2); return }
        guard FileManager.default.isExecutableFile(atPath: profile.binary) else {
            log("copy missing at \(profile.app); run install.sh")
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert(); a.messageText = "\(profile.name): its copy of Claude.app is missing"
            a.informativeText = "Run install.sh again to recreate it.\n\(profile.app)"; a.runModal()
            exitSoon(0.2); return
        }
        try? FileManager.default.createDirectory(atPath: profile.dataDir, withIntermediateDirectories: true)
        startRouter()
        ensureIcon(profile)
        ensure(attempt: 0)
    }

    func startRouter() {
        guard FileManager.default.fileExists(atPath: routerApp.path) else { log("router missing at \(routerApp.path); run install.sh"); return }
        let conf = NSWorkspace.OpenConfiguration(); conf.activates = false; conf.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: routerApp, configuration: conf) { _, err in if let e = err { log("router did not start: \(e.localizedDescription)") } }
    }

    /// Starts the account and checks it stays up; waits out a quit in progress if there is one.
    func ensure(attempt: Int) {
        if let running = runningCopy(of: profile) { activate(running.pid); exitSoon(1.0); return }
        guard attempt < 4 else { log("giving up starting \(profile.name)"); exitSoon(0.2); return }
        launchClaude(profile) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if runningCopy(of: self.profile) != nil { self.exitSoon(0.2) }
                else { log("\(self.profile.name) vanished right after starting, trying again"); self.ensure(attempt: attempt + 1) }
            }
        }
    }

    func exitSoon(_ delay: TimeInterval) { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSApp.terminate(nil) } }
}

// MARK: - Command line

func printStatus() {
    let instances = listInstances()
    func line(_ name: String, _ inst: Instance?, _ extra: String) { print("  \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(inst.map { "running (pid \($0.pid))" } ?? "not running")\(extra)") }
    print("Accounts")
    line("Claude", instances.first { $0.binary == mainBinary }, "")
    for p in profiles() { line(p.name, instances.first { $0.binary == p.binary && !$0.bare }, hasCustomIcon(p.app) ? "" : "   icon missing (update?): run install.sh, or allow Claude Router in App Management") }
    let routers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle(url: routerApp)?.bundleIdentifier ?? "-")
    print("Router")
    print("  \(routers.isEmpty ? "not running (macOS starts it at the next link)" : "running (pid \(routers[0].processIdentifier))")")
    print("  claude:// links go to: \(schemeOwner("claude") ?? "nobody")")
    print("Log: \(logPath)")
}

let cli = CommandLine.arguments
if cli.count == 2, cli[1] == "--status" { printStatus(); exit(0) }
if cli.count == 4, cli[1] == "--set-icon" {
    let ok = setCustomIcon(cli[2], on: cli[3])
    log("icon on \(cli[3]): \(ok ? "set" : "refused")")
    exit(ok ? 0 : 1)
}
if cli.count == 3, cli[1] == "--has-icon" { exit(hasCustomIcon(cli[2]) ? 0 : 1) }
if cli.count == 3, cli[1] == "--explain" {
    let instances = listInstances()
    print("instances:", instances.map { "\($0.label) (pid \($0.pid))" }.joined(separator: ", "))
    let r = Router(); if let f = frontmostByWindows(instances) { r.lastActive[f.pid] = Date() }
    let (dest, why) = instances.isEmpty ? ([], "no instance running") : r.targets(for: cli[2], among: instances)
    print("\(describe(cli[2])) -> \(dest.map { $0.label }.joined(separator: ", ")) — \(why)")
    exit(0)
}

let app = NSApplication.shared
let delegate: NSApplicationDelegate = role == "router" ? Router() : Launcher()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
