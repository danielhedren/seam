import Foundation

/// `seam threads` output, written for an agent to read (SPEC §13).
public enum ThreadText {
    public static func format(_ thread: ReviewThread, timeZone: TimeZone = .current) -> String {
        let anchor = thread.anchor
        let lines =
            anchor.lines.count == 1
            ? "\(anchor.lines.lowerBound)"
            : "\(anchor.lines.lowerBound)-\(anchor.lines.upperBound)"
        let side = anchor.side == .old ? " (old side)" : ""
        var text = [
            "#\(thread.id)  \(thread.isResolved ? "resolved" : "open")  "
                + "\(anchor.path):\(lines)\(side)  opened by \(thread.author)"
        ]
        let width = String(anchor.lines.upperBound).count
        for (offset, line) in anchor.text.enumerated() {
            let number = String(anchor.lines.lowerBound + offset)
            text.append(
                "    " + String(repeating: " ", count: width - number.count) + number + " │ "
                    + line)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for comment in thread.comments {
            text.append("  \(comment.author) · \(formatter.string(from: comment.date))")
            text += comment.body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + $0 }
        }
        return text.joined(separator: "\n")
    }

    /// `src/a.cs:12` or `src/a.cs:12-14`; nil when it isn't one of those.
    public static func location(_ argument: String) -> (path: String, lines: ClosedRange<Int>)? {
        guard let colon = argument.lastIndex(of: ":") else { return nil }
        let path = String(argument[..<colon])
        let range = argument[argument.index(after: colon)...].split(
            separator: "-", omittingEmptySubsequences: false)
        guard !path.isEmpty, (1...2).contains(range.count),
            let first = Int(range[0]), let last = Int(range.last ?? ""), first >= 1,
            first <= last
        else { return nil }
        return (path, first...last)
    }
}
