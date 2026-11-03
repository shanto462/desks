import Foundation

/// Checks a rule's title pattern. Pure, no side effects. Used by the engine (to skip bad rules)
/// and by the UI (to explain the problem next to the field).
public enum RulePattern {
    public static let maxLength = 200

    /// A short reason the pattern cannot be used, or nil when it is fine. An empty pattern is fine (any title).
    public static func problem(_ pattern: String) -> String? {
        if pattern.isEmpty { return nil }
        if pattern.count > maxLength { return "Too long: keep it under \(maxLength) characters." }
        if (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) == nil {
            return "Not a valid regular expression."
        }
        if hasRiskyRepetition(pattern) {
            return "Risky repetition: a repeated group like (a+)+ or (a|aa)+ can freeze Desks."
        }
        return nil
    }

    /// True when a repeated group (followed by *, + or {) can match the same text in more than one way:
    /// it contains a quantifier, a complex inner group, or alternatives that are not plain distinct
    /// words (like (a|aa)+ or (a|a?)+). These shapes can take exponential time.
    static func hasRiskyRepetition(_ pattern: String) -> Bool {
        struct Group { var start: Int; var complex = false; var alternation = false }
        let chars = Array(pattern)
        var stack: [Group] = []
        var escaped = false
        var inClass = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            defer { i += 1 }
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if inClass { if c == "]" { inClass = false }; continue }
            switch c {
            case "[":
                inClass = true
            case "(":
                stack.append(Group(start: i + 1))
            case ")":
                guard let group = stack.popLast() else { continue }
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                let repeated = next == "*" || next == "+" || next == "{"
                if repeated {
                    if group.complex { return true }
                    if group.alternation, !distinctWords(String(chars[group.start..<i])) { return true }
                }
                if group.complex || group.alternation || repeated, !stack.isEmpty {
                    stack[stack.count - 1].complex = true
                }
            case "*", "+", "{":
                if !stack.isEmpty { stack[stack.count - 1].complex = true }
            case "?":
                // At index 0 this reads the "?" itself; a leading "?" is invalid syntax anyway.
                let previous = chars[max(i - 1, 0)]
                // "(?" starts a group option; "+?" and "*?" are lazy forms of a quantifier already seen.
                if "(*+?}".contains(previous) { continue }
                if !stack.isEmpty { stack[stack.count - 1].complex = true }
            case "|":
                if !stack.isEmpty { stack[stack.count - 1].alternation = true }
            default:
                break
            }
        }
        return false
    }

    /// True when the group body is plain words separated by "|", none empty and none a prefix of another.
    private static func distinctWords(_ body: String) -> Bool {
        var text = Substring(body)
        if text.hasPrefix("?:") { text = text.dropFirst(2) }
        let special: Set<Character> = [".", "[", "]", "(", ")", "\\", "*", "+", "?", "{", "}", "^", "$"]
        if text.contains(where: { special.contains($0) }) { return false }
        let words = text.split(separator: "|", omittingEmptySubsequences: false).map { $0.lowercased() }
        if words.contains(where: \.isEmpty) { return false }
        for (a, first) in words.enumerated() {
            for second in words[(a + 1)...] where first.hasPrefix(second) || second.hasPrefix(first) {
                return false
            }
        }
        return true
    }
}
