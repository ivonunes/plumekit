/// Wraps a value so tests can move it into a @Sendable closure when the test
/// guarantees single-threaded access, e.g. handing the language server to its
/// dedicated thread.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
