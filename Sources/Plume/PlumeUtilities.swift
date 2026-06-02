import Foundation

extension String {
    func trimmingSuffix(_ suffix: Character) -> String {
        var output = self
        if output.last == suffix {
            output.removeLast()
        }
        return output
    }
}

func located<T>(_ context: PlumeSourceContext?, _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as PlumeError {
        throw error.withContext(context)
    }
}
