// Entry point. `DockWings --notify <status> <seconds> <command>` (used by
// docs/zsh-hook.zsh) posts a finished-command notice to the running app and
// exits; otherwise it starts the accessory app (no Dock icon, no menu bar)
// that owns the panels placed around the Dock by AppDelegate.
import AppKit

let args = CommandLine.arguments
if args.count >= 5, args[1] == "--notify" {
    DistributedNotificationCenter.default().postNotificationName(
        JobNotice.name, object: nil,
        userInfo: ["status": args[2], "seconds": args[3], "command": args[4...].joined(separator: " ")],
        deliverImmediately: true)
    exit(0)
}

// `DockWings --claude` (a Claude Code hook) reads the hook's JSON from stdin
// and passes event, session and project folder to the running app. For a
// PermissionRequest it then waits for the app's Allow or Deny.
if args.count >= 2, args[1] == "--claude" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    let field = { (key: String) -> String in json[key] as? String ?? "" }
    let tool = json["tool_input"] as? [String: Any] ?? [:]
    var detail = ((tool["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? ""
    for key in ["command", "file_path", "pattern", "description", "url"] where detail.isEmpty {
        if let value = tool[key] as? String {
            detail = key == "file_path" ? URL(fileURLWithPath: value).lastPathComponent : value
            break
        }
    }
    let info: [String: String] = [
        "event": field("hook_event_name"),
        "session": field("session_id"),
        "project": URL(fileURLWithPath: field("cwd")).lastPathComponent,
        "tool": field("tool_name"),
        "detail": String(detail.prefix(120)),
        "message": String(field("message").prefix(160)),
        "prompt": String(field("prompt").prefix(200)),
    ]
    var userInfo = info
    let request = UUID().uuidString
    // Questions and plans need your answer in Claude itself; only plain
    // permission prompts get Allow / Deny.
    let asks = field("hook_event_name") == "PermissionRequest"
        && !["AskUserQuestion", "ExitPlanMode"].contains(field("tool_name"))
        && UserDefaults.standard.object(forKey: "claudeApprovals") as? Bool ?? true
        && !NSRunningApplication.runningApplications(withBundleIdentifier: "local.dockwings").isEmpty
    if asks { userInfo["request"] = request }
    DistributedNotificationCenter.default().postNotificationName(ClaudeNotice.name, object: nil, userInfo: userInfo, deliverImmediately: true)
    guard asks else { exit(0) }
    // A permission prompt: wait for Allow or Deny from the notch or the
    // drawer, then answer Claude Code. No answer in time: print nothing, and
    // Claude Code asks the usual way.
    DistributedNotificationCenter.default().addObserver(forName: ClaudeNotice.answer, object: nil, queue: .main) { note in
        guard note.userInfo?["request"] as? String == request else { return }
        let behavior = note.userInfo?["allow"] as? String == "1" ? "allow" : "deny"
        var decision: [String: Any] = ["behavior": behavior]
        if behavior == "deny" { decision["message"] = "Denied from DockWings." }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let data = try? JSONSerialization.data(withJSONObject: out) { FileHandle.standardOutput.write(data) }
        exit(0)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(ClaudeHooks.permissionWait))
    exit(0)
}

// `DockWings --login` (re)installs the login / crash-restart launch agent.
if args.count >= 2, args[1] == "--login" {
    Launcher.set(true)
    print(Launcher.isOn ? "launch agent installed" : "launch agent not installed")
    exit(0)
}

// Started some other way while the background agent is on: hand over to
// launchd's copy, which restarts after a crash.
let migrated = Launcher.migrate()
if Launcher.handOver(reopen: !migrated) { exit(0) }

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
