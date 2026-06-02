import Foundation

extension ClientScriptCompiler {
    mutating func open(_ block: ClientScriptBlock) {
        indent += 1
        blocks.append(block)
    }

    mutating func closeBlock(lineNumber: Int, sourceLine: String) throws {
        guard let block = blocks.popLast() else {
            throw error("Unexpected } in Plume script.", line: lineNumber, sourceLine: sourceLine)
        }
        switch block {
        case .normal:
            indent -= 1
            emit("}")
        case .eventSingle:
            indent -= 1
            emit("});")
        case .eventSelector:
            indent -= 1
            emit("});")
            indent -= 1
            emit("}")
        }
    }

    mutating func closeForElse(lineNumber: Int, sourceLine: String) throws {
        guard let block = blocks.popLast(), block == .normal else {
            throw error(
                "Plume script else can only follow an if block.", line: lineNumber,
                sourceLine: sourceLine)
        }
        indent -= 1
        emit("} else {")
        open(.normal)
    }

    mutating func emit(_ line: String) {
        output.append(String(repeating: "  ", count: max(0, indent)) + line)
    }
}
