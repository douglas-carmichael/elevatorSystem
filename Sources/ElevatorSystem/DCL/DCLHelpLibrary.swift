import Foundation

// OpenVMS HELP library.
//
// Real OpenVMS HELP reads a compiled help library (SYS$HELP:HELPLIB.HLB),
// which the LIBRARIAN utility builds from `.HLP` source text. That source
// is a flat list of lines where a line beginning with a single digit N in
// column one names a *key* at level N, and every following line until the
// next key line is that key's help text:
//
//     1 COPY
//       Creates a new file ...
//     2 /LOG
//       Controls whether ...
//     1 DELETE
//       ...
//
// This file reproduces that scheme faithfully: `HelpLibrary.source` is a
// genuine `.HLP` database written in the DEC/VSI documentation style, and
// `HelpLibrary.parse` is the "librarian" that reads it into a tree of
// `HelpNode`s. The interactive HELP facility (DCLHelp.swift) then walks
// that tree exactly the way VMS HELP walks a compiled `.HLB`.
//
// Keeping the content as a parsed library -- rather than a hand-built
// Swift tree or a switch statement -- means new topics are authored in the
// same text format a VMS system manager would use for a site help library.

/// Case-folded glob supporting "*" (any run), used for wildcard topics.
private func helpGlobMatch(pattern: String, name: String) -> Bool {
    let parts = pattern.components(separatedBy: "*")
    var idx = name.startIndex
    for (i, part) in parts.enumerated() {
        if part.isEmpty { continue }
        guard let r = name.range(of: part, range: idx..<name.endIndex) else { return false }
        if i == 0 && r.lowerBound != name.startIndex { return false }
        idx = r.upperBound
    }
    if let last = parts.last, !last.isEmpty { return name.hasSuffix(last) }
    return true
}

/// One key in the help library: a topic or subtopic, its help text, and
/// the subtopics nested beneath it. Value type; the tree is immutable once
/// parsed.
struct HelpNode {
    let key: String
    let text: String
    let children: [HelpNode]

    func child(matching typed: String) -> [HelpNode] {
        // Normalize so a qualifier subtopic listed as "/SIZE" is reachable
        // whether the operator types "/SIZE" or "SIZE".
        func norm(_ s: String) -> String {
            var u = s.uppercased()
            if u.hasPrefix("/") { u.removeFirst() }
            return u
        }
        let want = norm(typed)
        // A wildcard request ("*", "SH*") returns every glob match.
        if want.contains("*") {
            return children.filter { helpGlobMatch(pattern: want, name: norm($0.key)) }
        }
        // An exact key match wins outright, so that a key which is a prefix
        // of a longer sibling (SET vs SETUP) is never ambiguous.
        if let exact = children.first(where: { norm($0.key) == want }) {
            return [exact]
        }
        // Otherwise VMS-style abbreviation: any subtopic the typed text is a
        // leading abbreviation of. Several matches => ambiguous.
        return children.filter { norm($0.key).hasPrefix(want) }
    }
}

/// Reads the `.HLP` source into a tree and answers path lookups.
enum HelpLibrary {

    /// Parse the `.HLP` source into a synthetic root whose children are the
    /// level-1 topics. Substitutions ($OSTITLE$, $STOREROOT$, ...) are
    /// resolved as the library is read so the text can name the live node,
    /// user, version and on-disk paths.
    static func parse(source: String, substitutions: [String: String]) -> HelpNode {
        var subs = source
        for (token, value) in substitutions {
            subs = subs.replacingOccurrences(of: token, with: value)
        }

        // Frame stack: frame[i] collects the children accumulating for a key
        // at level i+1. `pendingKey`/`pendingText` hold the key currently
        // having its body read.
        struct Frame { var key: String; var level: Int; var text: [String]; var children: [HelpNode] }
        var stack: [Frame] = []
        var topLevel: [HelpNode] = []

        func fold(downTo level: Int) {
            // Close every open frame deeper than `level`, folding each into
            // its parent's children (or into the top-level list).
            while let top = stack.last, top.level >= level {
                let node = HelpNode(key: top.key,
                                    text: trimBody(top.text),
                                    children: top.children)
                stack.removeLast()
                if stack.isEmpty {
                    topLevel.append(node)
                } else {
                    stack[stack.count - 1].children.append(node)
                }
            }
        }

        for rawLine in subs.components(separatedBy: "\n") {
            if let (level, key) = keyLine(rawLine) {
                fold(downTo: level)
                stack.append(Frame(key: key, level: level, text: [], children: []))
            } else if !stack.isEmpty {
                stack[stack.count - 1].text.append(rawLine)
            }
            // Lines before the first key are ignored (file header comments).
        }
        fold(downTo: 1)

        return HelpNode(key: "HELP", text: rootIntro, children: topLevel.sorted { $0.key < $1.key })
    }

    /// A key line is `<digit><space><name>` with the digit in column one.
    /// The name must start with a letter, "@", "_" or "/" so that numbered
    /// body text ("1. first step") is never mistaken for a level marker.
    private static func keyLine(_ line: String) -> (level: Int, key: String)? {
        let chars = Array(line)
        guard chars.count >= 3,
              let level = chars[0].wholeNumberValue, (1...9).contains(level),
              chars[1] == " " else { return nil }
        let name = String(chars[2...]).trimmingCharacters(in: .whitespaces)
        guard let first = name.first,
              first.isLetter || first == "@" || first == "_" || first == "/" else { return nil }
        return (level, name)
    }

    /// Normalize a key's body: drop leading and trailing blank lines, strip
    /// trailing whitespace, and dedent by the common leading indentation so
    /// the reader can re-apply per-level indentation from a column-zero
    /// baseline. Relative indentation (a Format: line above its indented
    /// syntax) is preserved.
    private static func trimBody(_ lines: [String]) -> String {
        var body = lines
        while let f = body.first, f.trimmingCharacters(in: .whitespaces).isEmpty { body.removeFirst() }
        while let l = body.last, l.trimmingCharacters(in: .whitespaces).isEmpty { body.removeLast() }

        let leading = { (s: String) -> Int in s.prefix { $0 == " " }.count }
        let minIndent = body
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(leading)
            .min() ?? 0

        return body.map { line in
            let trimmedTail = String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            if trimmedTail.isEmpty { return "" }
            return String(trimmedTail.dropFirst(minIndent))
        }.joined(separator: "\n")
    }

    /// Text shown for bare `HELP` (and `HELP HELP`): the standard VMS HELP
    /// facility introduction. Its "Additional information available:" list
    /// is the set of level-1 topics.
    static let rootIntro = """
    The HELP command invokes the HELP facility to display information about
    a command or topic. In response to the "Topic?" prompt, you can:

      o  Type the name of the command or topic for which you need help.

      o  Type INSTRUCTIONS for more detailed instructions on how to use
         HELP.

      o  Type HINTS if you are not sure of the name of the command or
         topic for which you need help.

      o  Type a question mark (?) to redisplay the most recently requested
         text.

      o  Press the RETURN key one or more times to exit from HELP.

    You can abbreviate any topic name, although ambiguous abbreviations
    result in all matches being displayed. Enter a question mark or an
    asterisk (*) to list every topic at the current level. To request
    help on a subtopic directly, type the topic and subtopic on one line,
    for example, HELP SHOW PROCESS.
    """
}
