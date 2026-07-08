# PlumeKit

A delightful Swift web framework that runs anywhere. Write your routes, models and views
once: the same code runs natively on your own server, compiles to WebAssembly
for Cloudflare Workers and deploys to AWS Lambda, with nothing to rewrite and
no per-platform branches.

```swift
@Model final class Post: Model {
    var id: Int
    var title: String
    var published = false
}

app.get("/posts") { _ in
    let posts = try await Post.where(Post.published == true)
        .order(by: Post.id, .descending)
        .all()
    return .view(postsPage(posts: posts))
}
```

Batteries included: routing, a type-safe ORM with migrations, the **Plume**
templating language, auth, validations, background jobs, scheduled tasks,
real-time channels, transactions, flash messages and one-command deploys.
All of it works out of the box and behaves identically on every target.

## Install

```sh
brew install ivonunes/tap/plumekit
# or
curl -fsSL https://install.plumekit.dev | sh
```

## Quickstart

```sh
plumekit new myapp
cd myapp
./plumekit dev            # serve on http://127.0.0.1:8080, restart on change

./plumekit generate resource Post title:string    # a working CRUD resource
./plumekit migrate
./plumekit test

./plumekit deploy         # the same app, live on your default target
```

## Documentation

Everything lives at **[plumekit.dev](https://plumekit.dev)**:

- [Getting started](https://plumekit.dev/docs/start/getting-started/): install to first deploy.
- [Tutorial](https://plumekit.dev/docs/start/tutorial/): build a small app in 15 minutes.
- [Documentation](https://plumekit.dev/docs/): every feature, in depth.

(The same docs live in [docs/](docs/) in this repo.)

## Developing the framework

```sh
swift build
swift test                    # framework + templating suites
./support/embedded-check.sh   # the core must stay Embedded-Wasm-clean
./support/embedded-gate.sh    # native and Wasm renders must be byte-identical
```

`Fixtures/` holds the verification apps these gates build. Editor extensions for
the Plume language (VS Code, Nova) live under `editors/`.
