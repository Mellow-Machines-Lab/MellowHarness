import Foundation

/// A folder of Markdown files for the prompt's sections, read once and never written: each file by its path without
/// `.md` (`steering["tone/calm"]`), with `<!-- comments -->` and a leading
/// `---` front matter block left out. The front matter is kept apart, for
/// the app to read.
public struct Steering: Equatable, Sendable {
    /// Each file's text, cleaned, by its path without `.md`.
    public var files: [String: String]
    /// Each file's front matter, as written, by the same path.
    public var frontMatter: [String: String]

    public init(files: [String: String] = [:], frontMatter: [String: String] = [:]) {
        self.files = files
        self.frontMatter = frontMatter
    }

    /// Reads every `.md` file under `folder`.
    public init(folder: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            throw SteeringError("\(folder.path) can't be read")
        }
        var files: [String: String] = [:], frontMatter: [String: String] = [:]
        let root = folder.standardizedFileURL.path
        for case let url as URL in walker where url.pathExtension == "md" {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            let path = String(full.dropFirst(root.count + 1).dropLast(3))
            let text = try String(contentsOf: url, encoding: .utf8)
            let (front, body) = Steering.frontMatter(text)
            files[path] = Steering.clean(body)
            if !front.isEmpty { frontMatter[path] = front }
        }
        self.init(files: files, frontMatter: frontMatter)
    }

    /// A file's text, or "" for one that isn't there.
    public subscript(_ path: String) -> String { files[path] ?? "" }

    /// Splits a leading `---` block from the rest.
    public static func frontMatter(_ text: String) -> (String, String) {
        guard text.hasPrefix("---\n"),
              let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
        else { return ("", text) }
        return (String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]), String(text[end.upperBound...]))
    }

    /// The text without `<!-- … -->` comments, trimmed.
    public static func clean(_ text: String) -> String {
        var s = text
        while let start = s.range(of: "<!--"), let end = s.range(of: "-->", range: start.upperBound..<s.endIndex) {
            s.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SteeringError: Error, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
