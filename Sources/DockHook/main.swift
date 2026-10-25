// dock-hook <claude|codex>: the command Claude Code and Codex run for each hook event. It reads
// the event's JSON from stdin, keeps only what the light strip needs (which app, the event, the
// session, a notification's type, a tool's name) and hands it to the StreamDock app over a local
// socket. The prompt text, tool inputs and everything else are dropped here.
//
// It must never get in the way: it prints nothing (Claude adds a UserPromptSubmit hook's output
// to the conversation, Codex requires JSON from a Stop hook), always exits 0, gives up after one
// second, and does nothing at all when StreamDock is not running (no socket to connect to).

import Foundation

signal(SIGALRM) { _ in _exit(0) }
signal(SIGPIPE, SIG_IGN)
alarm(1)

let app = CommandLine.arguments.dropFirst().first ?? ""
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
let message = [
    "app": app,
    "event": event["hook_event_name"] as? String,
    "session": event["session_id"] as? String,
    "kind": event["notification_type"] as? String,
    "tool": event["tool_name"] as? String,  // the tool's name only (exec, Bash…), never its input
].compactMapValues { $0 }
guard var line = try? JSONSerialization.data(withJSONObject: message) else { exit(0) }
line.append(0x0A)

let path = NSHomeDirectory() + "/Library/Application Support/StreamDock/agent.sock"
let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketFD >= 0 else { exit(0) }
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let capacity = MemoryLayout.size(ofValue: address.sun_path)
guard path.utf8.count < capacity else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
}
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
if connected == 0 {
    _ = line.withUnsafeBytes { write(socketFD, $0.baseAddress, $0.count) }
}
close(socketFD)
exit(0)
