import Testing
@testable import PlumeCore
import PlumeServer
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Test func envSecretsReadsAndMissesThroughHandle() async throws {
    // A unique name so we don't collide with the ambient environment.
    let name = "PLUMEKIT_TEST_SECRET_X1"
    setenv(name, "hunter2 & <ok>", 1)
    defer { unsetenv(name) }

    let secrets = Secrets(EnvSecrets())
    #expect(try await secrets.secretString(name) == "hunter2 & <ok>")
    #expect(try await secrets.has(name) == true)

    // Absent secret → nil / false, never a thrown error.
    #expect(try await secrets.secret("PLUMEKIT_TEST_SECRET_ABSENT") == nil)
    #expect(try await secrets.has("PLUMEKIT_TEST_SECRET_ABSENT") == false)
}

@Test func secretsClosureInitWorks() async throws {
    // The non-adapter init (used by the wasm host bridge) round-trips bytes.
    let secrets = Secrets(secret: { name in name == "K" ? Array("V".utf8) : nil })
    #expect(try await secrets.secretString("K") == "V")
    #expect(try await secrets.secret("nope") == nil)
}
