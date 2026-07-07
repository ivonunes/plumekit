//
//  PlumeForLoop.swift
//  PlumeRuntime
//
//  The loop metadata Plume exposes as `forloop` inside `@for` bodies, mirroring
//  the interpreting renderer's `forloop` dictionary. Embedded-clean: a plain
//  value type over `Int`/`Bool`.
//

public struct PlumeForLoop {
    public let index0: Int
    public let length: Int

    public init(index: Int, count: Int) {
        self.index0 = index
        self.length = count
    }

    /// 1-based index.
    public var index: Int { index0 + 1 }
    /// Items remaining including the current one.
    public var rindex: Int { length - index0 }
    /// Items remaining after the current one.
    public var rindex0: Int { length - index0 - 1 }
    public var first: Bool { index0 == 0 }
    public var last: Bool { index0 == length - 1 }
    /// Alias for `length`, matching Plume's `forloop.size`.
    public var size: Int { length }
    public var count: Int { length }
}
