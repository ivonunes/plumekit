import Foundation

// CI workflow templates for `plumekit generate ci --provider <github|gitlab|forgejo>`.
// Test-on-PR + deploy-on-push (push → main runs `./plumekit deploy`, which migrates
// then builds + deploys). GitHub and Forgejo share the Actions YAML — Forgejo Actions
// is GitHub-compatible — differing only in the workflows directory.
enum CITemplates {
    /// The files to write for a provider + the project's default build target and
    /// capabilities. `database` matters to the test job: the Lambda target links the
    /// Postgres driver whenever it's enabled (whatever the native driver), and
    /// `swift test` builds all targets, so the job needs libpq-dev.
    static func files(provider: String, target: String,
                      capabilities: Set<String> = []) -> [(path: String, contents: String)]? {
        let needsPostgres = capabilities.contains("database")
        switch provider {
        case "github":
            return [(".github/workflows/test.yml", actionsTest(needsPostgres: needsPostgres)),
                    (".github/workflows/deploy.yml", actionsDeploy(target: target)),
                    (".github/dependabot.yml", dependabot)]
        case "forgejo":
            return [(".forgejo/workflows/test.yml", actionsTest(needsPostgres: needsPostgres)),
                    (".forgejo/workflows/deploy.yml", actionsDeploy(target: target)),
                    ("renovate.json", renovate)]
        case "gitlab":
            return [(".gitlab-ci.yml", gitlab(target: target, needsPostgres: needsPostgres)),
                    ("renovate.json", renovate)]
        default:
            return nil
        }
    }

    // Pinned to a patch release the CLI knows a Wasm SDK for (it auto-installs the
    // matching SDK on the first Cloudflare build) — a floating `swift:6.3` tag would
    // drift to a toolchain the CLI can't provision yet.
    private static let swiftImage = "swift:6.3.2"

    // Weekly dependency PRs for the app's Swift packages and the workflows' actions.
    // GitHub-only: Dependabot is a GitHub service, not part of the Actions syntax.
    private static let dependabot = """
    version: 2
    updates:
      - package-ecosystem: swift
        directory: "/"
        schedule:
          interval: weekly
        open-pull-requests-limit: 10
      - package-ecosystem: github-actions
        directory: "/"
        schedule:
          interval: weekly
        open-pull-requests-limit: 10
    """

    // Dependabot's equivalent on Forgejo and GitLab is Renovate: the repo carries the
    // config and a Renovate bot on the instance acts on it. `config:recommended`
    // covers Swift packages and workflow actions/images with its default managers.
    private static let renovate = """
    {
      "$schema": "https://docs.renovatebot.com/renovate-schema.json",
      "extends": ["config:recommended", "schedule:weekly"]
    }
    """

    // MARK: GitHub / Forgejo Actions (shared syntax)

    private static func actionsTest(needsPostgres: Bool) -> String {
        // With `database` on, `swift test` builds the Lambda target, which links the
        // Postgres driver — so libpq headers are required even for SQLite-native apps.
        let postgresStep = needsPostgres
            ? "      - run: apt-get update && apt-get install -y libpq-dev\n"
            : "      # Using the Postgres driver? apt-get install -y libpq-dev first.\n"
        return """
        name: Test
        on:
          pull_request:
            branches: [main]
        jobs:
          test:
            runs-on: ubuntu-latest
            container:
              image: \(swiftImage)
            steps:
              - uses: actions/checkout@v7
              - uses: actions/cache@v6
                with:
                  path: .build
                  key: swiftpm-test-${{ hashFiles('Package.resolved') }}
                  restore-keys: swiftpm-test-
        \(postgresStep)      - run: swift test
        """
    }

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
              image: \(swiftImage)
            steps:
              - uses: actions/checkout@v7
              - uses: actions/cache@v6
                with:
                  path: .build
                  key: swiftpm-deploy-${{ hashFiles('Package.resolved') }}
                  restore-keys: swiftpm-deploy-
        \(indentedSetup(target: target, indent: "      "))
              # `plumekit deploy` migrates, builds, and deploys the \(target) target.
              - run: ./plumekit deploy --target \(target)
                env:
        \(indentedSecrets(target: target, indent: "          "))
        """
    }

    // MARK: GitLab CI

    private static func gitlab(target: String, needsPostgres: Bool) -> String {
        let testScript = needsPostgres
            ? "  script:\n    - apt-get update && apt-get install -y libpq-dev\n    - swift test"
            : "  # Using the Postgres driver? apt-get install -y libpq-dev first.\n  script:\n    - swift test"
        return """
        stages: [test, deploy]

        test:
          stage: test
          image: \(swiftImage)
          rules:
            - if: $CI_PIPELINE_SOURCE == "merge_request_event"
          cache:
            key:
              files: [Package.resolved]
              prefix: swiftpm-test
            paths: [.build]
        \(testScript)

        deploy:
          stage: deploy
          image: \(swiftImage)
          rules:
            - if: $CI_COMMIT_BRANCH == "main"
          cache:
            key:
              files: [Package.resolved]
              prefix: swiftpm-deploy
            paths: [.build]
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
            // curl: the ./plumekit wrapper fetches the CLI release with it, and the
            // swift image doesn't ship it. The CLI provisions everything else (the
            // Wasm SDK, wasm-opt) and deploys over the Cloudflare API directly.
            lines = [
                "- run: apt-get update && apt-get install -y curl ca-certificates",
            ]
        case "aws":
            lines = ["- run: apt-get update && apt-get install -y curl ca-certificates libpq-dev awscli"]
        default:  // native — docker is preinstalled on ubuntu runners
            lines = ["- run: apt-get update && apt-get install -y curl ca-certificates"]
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
                "- apt-get update && apt-get install -y curl ca-certificates",
                "- ./plumekit deploy --target cloudflare",
            ]
        case "aws":
            lines = ["- apt-get update && apt-get install -y curl ca-certificates libpq-dev awscli",
                     "- ./plumekit deploy --target aws"]
        default:
            lines = ["- apt-get update && apt-get install -y curl ca-certificates",
                     "- ./plumekit deploy --target native"]
        }
        return lines.map { "    " + $0 }.joined(separator: "\n")
    }
}
