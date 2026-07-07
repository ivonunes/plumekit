import Foundation

// CI workflow templates for `plumekit generate ci --provider <github|gitlab|forgejo>`.
// Test-on-PR + deploy-on-push (push → main runs `./plumekit deploy`, which migrates
// then builds + deploys). GitHub and Forgejo share the Actions YAML — Forgejo Actions
// is GitHub-compatible — differing only in the workflows directory.
enum CITemplates {
    /// The files to write for a provider + the project's default build target.
    static func files(provider: String, target: String) -> [(path: String, contents: String)]? {
        switch provider {
        case "github":
            return [(".github/workflows/test.yml", actionsTest),
                    (".github/workflows/deploy.yml", actionsDeploy(target: target))]
        case "forgejo":
            return [(".forgejo/workflows/test.yml", actionsTest),
                    (".forgejo/workflows/deploy.yml", actionsDeploy(target: target))]
        case "gitlab":
            return [(".gitlab-ci.yml", gitlab(target: target))]
        default:
            return nil
        }
    }

    // MARK: GitHub / Forgejo Actions (shared syntax)

    private static let actionsTest = """
    name: Test
    on:
      pull_request:
        branches: [main]
    jobs:
      test:
        runs-on: ubuntu-latest
        container:
          image: swift:6.3
        steps:
          - uses: actions/checkout@v6
          # System libs the swift image lacks: libsqlite3 (the default SQLite driver) and
          # libpq (the Postgres driver, if used).
          - run: apt-get update && apt-get install -y libsqlite3-dev libpq-dev
          - run: swift test
    """

    private static func actionsDeploy(target: String) -> String {
        """
        name: Deploy
        on:
          push:
            branches: [main]
        jobs:
          deploy:
            runs-on: ubuntu-latest
            container:
              image: swift:6.3
            steps:
              - uses: actions/checkout@v6
        \(indentedSetup(target: target, indent: "      "))
              # `plumekit deploy` migrates, builds, and deploys the \(target) target.
              - run: ./plumekit deploy --target \(target)
                env:
        \(indentedSecrets(target: target, indent: "          "))
        """
    }

    // MARK: GitLab CI

    private static func gitlab(target: String) -> String {
        """
        stages: [test, deploy]

        test:
          stage: test
          image: swift:6.3
          rules:
            - if: $CI_PIPELINE_SOURCE == "merge_request_event"
          script:
            - swift test

        deploy:
          stage: deploy
          image: swift:6.3
          rules:
            - if: $CI_COMMIT_BRANCH == "main"
          # Set the secrets below as masked CI/CD variables in your GitLab project.
          script:
        \(gitlabDeployScript(target: target))
        """
    }

    // MARK: per-target setup + secrets

    private static func indentedSetup(target: String, indent: String) -> String {
        let lines: [String]
        switch target {
        case "cloudflare":
            lines = [
                "- name: Install the Embedded WebAssembly SDK",
                "  run: swift sdk install https://download.swift.org/swift-6.3.2-release/wasm-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_wasm.artifactbundle.tar.gz --checksum a61f0584c93283589f8b2f42db05c1f9a182b506c2957271402992655591dd7c",
                "- run: apt-get update && apt-get install -y binaryen",
                "- uses: actions/setup-node@v6",
            ]
        case "aws":
            lines = ["- run: apt-get update && apt-get install -y libpq-dev awscli"]
        default:  // native — docker is preinstalled on ubuntu runners
            lines = []
        }
        return lines.map { indent + $0 }.joined(separator: "\n")
    }

    private static func indentedSecrets(target: String, indent: String) -> String {
        let pairs: [String]
        switch target {
        case "cloudflare":
            pairs = ["CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}",
                     "CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}"]
        case "aws":
            pairs = ["AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}",
                     "AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}",
                     "AWS_REGION: ${{ secrets.AWS_REGION }}",
                     "AWS_FUNCTION_NAME: your-lambda-function-name",
                     "DATABASE_URL: ${{ secrets.DATABASE_URL }}"]
        default:  // native — add your registry login + `docker push` after the build
            pairs = ["REGISTRY_TOKEN: ${{ secrets.REGISTRY_TOKEN }}"]
        }
        return pairs.map { indent + $0 }.joined(separator: "\n")
    }

    private static func gitlabDeployScript(target: String) -> String {
        var lines: [String]
        switch target {
        case "cloudflare":
            lines = [
                "- swift sdk install https://download.swift.org/swift-6.3.2-release/wasm-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_wasm.artifactbundle.tar.gz --checksum a61f0584c93283589f8b2f42db05c1f9a182b506c2957271402992655591dd7c",
                "- apt-get update && apt-get install -y binaryen nodejs npm",
                "- ./plumekit deploy --target cloudflare",
            ]
        case "aws":
            lines = ["- apt-get update && apt-get install -y libpq-dev awscli",
                     "- ./plumekit deploy --target aws"]
        default:
            lines = ["- ./plumekit deploy --target native"]
        }
        return lines.map { "    " + $0 }.joined(separator: "\n")
    }
}
