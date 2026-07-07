import PlumeCore

// The native composition root: assembles a request `Context` from the native
// adapter set (file-backed KV, SQLite, stdout logging). The Cloudflare equivalent
// is assembled in PlumeWorker from the JSPI adapters. Same `Context` shape, same
// handler code — only the wiring differs per target (the "manifest swap changes
// the adapter set with zero app-code change", here expressed at the entry point).
public enum NativeBindings {
    /// Build the native context. `databasePath` is a SQLite file (or ":memory:");
    /// `blobDirectory` holds the filesystem blob store.
    public static func context(
        kvDirectory: String,
        databasePath: String,
        blobDirectory: String
    ) throws -> Context {
        let kvStore = FileKVStore(directory: kvDirectory)
        let kv = KV(
            get: { key in await kvStore.get(key) },
            putExpiring: { key, value, expiresAt in await kvStore.put(key, value, expiresAt: expiresAt) }
        )
        let database = Database.interactiveTransactions(try SQLiteDatabase(path: databasePath), dialect: .sqlite)
        let storage = Storage(FileStorage(directory: blobDirectory))
        return Context(kv: kv, database: database, storage: storage, log: { message in print(message) })
    }
}
