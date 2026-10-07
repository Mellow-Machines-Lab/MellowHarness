import Foundation
import MellowHarness

// `mellowharness-emit`: sends one event to a harness's socket.
//   mellowharness-emit --socket PATH SOURCE KIND [key=value ...] [--line TEXT]
// A whole number written plainly is one, `true` and `false` are yes and no, and the rest are strings.

let usage = """
    usage: mellowharness-emit --socket PATH SOURCE KIND [key=value ...] [--line TEXT]
    Sends one event to the harness's socket at PATH (EventServer), e.g.
      mellowharness-emit --socket /tmp/beacon.sock ci build_failed branch=main run=812
    A whole number written plainly (812, -3; not 007) is one, true and false are yes and no, the rest strings.
    --line gives the event a line of its own, for a kind registered with no transform.
    """

/// The flags taken out of the words, and the words left.
func parse(_ words: [String]) -> (socket: String?, line: String?, rest: [String]) {
    var rest = words, socket: String?, line: String?
    for flag in ["--socket", "--line"] {
        guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else { continue }
        if flag == "--socket" { socket = rest[i + 1] } else { line = rest[i + 1] }
        rest.removeSubrange(i...(i + 1))
    }
    return (socket, line, rest)
}

let (socket, line, rest) = parse(Array(CommandLine.arguments.dropFirst()))
if rest.contains("--help") || rest.contains("-h") {
    print(usage)
    exit(0)
}
guard let socket, var event = EventServer.event(from: rest) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
event.line = line
do {
    try EventServer.send(event, to: socket)
} catch {
    FileHandle.standardError.write(Data("mellowharness-emit: couldn't send to \(socket): \(error)\n".utf8))
    exit(1)
}
