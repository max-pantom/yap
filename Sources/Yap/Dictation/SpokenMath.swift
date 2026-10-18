import Foundation

/// Spoken arithmetic. "What's 40 plus 20" pastes "60"; "the total is 40 plus 20 equals" pastes
/// "the total is 40 + 20 = 60". A small evaluator of its own (never NSExpression, which can crash on odd input).
enum SpokenMath {
    enum Result: Equatable {
        case answer(String)            // the whole utterance was a question: paste just the number
        case inline(String)            // a sentence ending in "equals": paste it with the sum worked out
    }

    static func evaluate(_ utterance: String) -> Result? {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))
        let lower = text.lowercased()

        // "calculate 15% of 200", "what's 40 plus 20", "how much is 12 times 7"
        for lead in ["calculate ", "compute ", "what is ", "what's ", "whats ", "how much is "] where lower.hasPrefix(lead) {
            let rest = String(text.dropFirst(lead.count))
            if let tokens = tokenize(rest), tokens.contains(where: \.isOperator), let v = value(tokens) {
                return .answer(format(v))
            }
        }

        // "… 40 plus 20 equals" / "… 40 + 20 ="
        for tail in [" equals what", " is equal to", " equals", " ="] where lower.hasSuffix(tail) {
            let body = String(text.dropLast(tail.count))
            let words = body.split(separator: " ").map(String.init)
            // Longest run of words at the end that reads as maths.
            for start in 0..<words.count {
                let candidate = words[start...].joined(separator: " ")
                guard let tokens = tokenize(candidate), tokens.contains(where: \.isOperator), tokens.first?.isValue == true,
                      let v = value(tokens) else { continue }
                let prefix = words[..<start].joined(separator: " ")
                let expr = tokens.map(\.display).joined(separator: " ").replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " )", with: ")")
                    .replacingOccurrences(of: " % × ", with: "% of ").replacingOccurrences(of: " %", with: "%")
                return .inline((prefix.isEmpty ? "" : prefix + " ") + "\(expr) = \(format(v))")
            }
        }
        return nil
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(Double), op(Character), open, close, percent
        var isOperator: Bool { if case .op = self { return true }; if case .percent = self { return true }; return false }
        var isValue: Bool { if case .number = self { return true }; return self == .open }
        var display: String {
            switch self {
            case .number(let v): format(v)
            case .op(let c): c == "*" ? "×" : c == "/" ? "÷" : c == "^" ? "^" : String(c)
            case .open: "("
            case .close: ")"
            case .percent: "%"
            }
        }
    }

    private static let phrases: [(String, String)] = [
        ("multiplied by", "*"), ("times", "*"), ("divided by", "/"), ("over", "/"), ("plus", "+"), ("add", "+"),
        ("minus", "-"), ("take away", "-"), ("to the power of", "^"), ("squared", "^ 2"), ("cubed", "^ 3"),
        ("percent of", "% *"), ("per cent of", "% *"), ("percent", "%"), ("open bracket", "("), ("close bracket", ")"),
        ("x", "*"), ("×", "*"), ("÷", "/"), ("of", "*"),
    ]

    /// Words and symbols to tokens; nil if anything isn't maths.
    static func tokenize(_ s: String) -> [Token]? {
        var t = " " + s.lowercased().replacingOccurrences(of: ",", with: "") + " "
        for sym in ["+", "-", "*", "/", "^", "(", ")", "%", "×", "÷", "="] { t = t.replacingOccurrences(of: sym, with: " \(sym) ") }
        for (word, sym) in phrases { t = t.replacingOccurrences(of: " \(word) ", with: " \(sym) ") }
        let words = t.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var out: [Token] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            switch w {
            case "+", "-", "*", "/", "^": out.append(.op(Character(w)))
            case "(": out.append(.open)
            case ")": out.append(.close)
            case "%": out.append(.percent)
            default:
                if let v = Double(w) { out.append(.number(v)) }
                else if let (v, used) = numberWords(Array(words[i...])) { out.append(.number(v)); i += used; continue }
                else { return nil }
            }
            i += 1
        }
        // "minus 5" at the start, or after an operator, is a negative number.
        var fixed: [Token] = []
        for tok in out {
            if case .number(let v) = tok, case .op("-")? = fixed.last, fixed.count == 1 || { if case .op = fixed[fixed.count - 2] { return true }; return fixed[fixed.count - 2] == .open }() {
                fixed.removeLast(); fixed.append(.number(-v))
            } else { fixed.append(tok) }
        }
        return fixed
    }

    private static let units = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                                "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                                "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
                                "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    /// "two hundred and fifty" → (250, 4 words used).
    private static func numberWords(_ ws: [String]) -> (Double, Int)? {
        var total = 0.0, current = 0.0, used = 0, any = false
        for w in ws {
            let parts = w.split(separator: "-").map(String.init)   // "twenty-five"
            if parts.allSatisfy({ units[$0] != nil }) { current += parts.reduce(0) { $0 + Double(units[$1]!) }; any = true }
            else if w == "hundred", any { current *= 100 }
            else if w == "thousand", any { total += current * 1_000; current = 0 }
            else if w == "million", any { total += current * 1_000_000; current = 0 }
            else if w == "and", any { }
            else { break }
            used += 1
        }
        return any ? (total + current, used) : nil
    }

    // MARK: Evaluation (precedence climbing)

    static func value(_ tokens: [Token]) -> Double? { var p = Parser(tokens); return p.parse() }

    private struct Parser {
        let tokens: [Token]; var i = 0
        init(_ t: [Token]) { tokens = t }

        mutating func parse() -> Double? {
            guard let v = expr(0), i == tokens.count, v.isFinite else { return nil }
            return v
        }
        private static func prec(_ c: Character) -> Int { c == "+" || c == "-" ? 1 : c == "^" ? 3 : 2 }

        private mutating func expr(_ minPrec: Int) -> Double? {
            guard var lhs = atom() else { return nil }
            while i < tokens.count, case .op(let c) = tokens[i], Self.prec(c) >= minPrec {
                i += 1
                guard let rhs = expr(c == "^" ? Self.prec(c) : Self.prec(c) + 1) else { return nil }
                switch c {
                case "+": lhs += rhs
                case "-": lhs -= rhs
                case "*": lhs *= rhs
                case "/": guard rhs != 0 else { return nil }; lhs /= rhs
                default: lhs = pow(lhs, rhs)
                }
            }
            return lhs
        }

        private mutating func atom() -> Double? {
            guard i < tokens.count else { return nil }
            var v: Double
            switch tokens[i] {
            case .number(let n): v = n; i += 1
            case .open:
                i += 1
                guard let inner = expr(0), i < tokens.count, tokens[i] == .close else { return nil }
                i += 1; v = inner
            default: return nil
            }
            while i < tokens.count, tokens[i] == .percent { v /= 100; i += 1 }
            return v
        }
    }

    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        f.usesGroupingSeparator = abs(v) >= 10_000
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
