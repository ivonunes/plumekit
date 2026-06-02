import Foundation

struct ClientScriptArgument {
    var label: String?
    var expression: String
}

struct ClientScriptMethodCall {
    var target: String
    var name: String
    var arguments: [ClientScriptArgument]
}

enum ClientScriptBlock {
    case normal
    case eventSingle
    case eventSelector
}
