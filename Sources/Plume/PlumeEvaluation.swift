import Foundation

struct PlumeEvaluation {
    var value: Any?
    var raw: Bool
}

struct PlumeAction: CustomStringConvertible {
    var expression: String
    var description: String { expression }
}

struct PlumeBinding {
    var expression: String
    var rendered: String
    var action: Bool
}

struct PlumeFragment {
    var html = ""
    var scopes: [String] = []

    mutating func append(_ html: String) {
        self.html += html
    }

    mutating func append(_ fragment: PlumeFragment) {
        html += fragment.html
        scopes.append(contentsOf: fragment.scopes)
    }
}
