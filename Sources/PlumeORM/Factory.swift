import _Concurrency
import PlumeCore

// Model factories for tests and seeds. Define a factory on a model,
// then build unsaved instances or create persisted rows — for seeders and tests:
//
//     extension User {
//         static let factory = Factory { User(email: "user@example.com", passwordHash: "x") }
//     }
//     let user  = try await User.factory.create(in: db)
//     let admin = try await User.factory.create(in: db) { $0.email = "admin@example.com" }
//     let users = try await User.factory.createMany(3, in: db) { i, u in u.email = "u\(i)@x.com" }
public struct Factory<M: Model>: Sendable {
    private let build: @Sendable () -> M

    /// `build` must return a fresh instance each call (default attribute values).
    public init(_ build: @escaping @Sendable () -> M) { self.build = build }

    /// An unsaved instance, with optional overrides.
    public func make(_ configure: (M) -> Void = { _ in }) -> M {
        let model = build()
        configure(model)
        return model
    }

    /// Build, INSERT, and return the row (its `id` is populated by `save`).
    @discardableResult
    public func create(in db: Database? = nil, _ configure: (M) -> Void = { _ in }) async throws -> M {
        let model = make(configure)
        _ = try await model.save(in: db)
        return model
    }

    /// Create `count` rows; the closure receives each row's index for per-row overrides.
    @discardableResult
    public func createMany(_ count: Int, in db: Database? = nil,
                           _ configure: (Int, M) -> Void = { _, _ in }) async throws -> [M] {
        var models: [M] = []
        models.reserveCapacity(count)
        for index in 0..<count {
            let model = make { configure(index, $0) }
            _ = try await model.save(in: db)
            models.append(model)
        }
        return models
    }
}
