# Unreleased

<!-- unreleased-intro-start (support/prepare-release.sh drops this block at release) -->
The notes for the next release: everything below is in `main` and ships
together when the version is tagged.
<!-- unreleased-intro-end -->

## `plumekit routes` shows where each route is registered

Every route now records the file and line of the call that registered it, and `plumekit routes` prints that as a third column:

```
GET	/posts/:id	Sources/App/Routes.swift:14
```

Routes registered through `app.resources(...)` or a route group point at the `resources`/group call. The location is available to your own code as `app.routeList`, whose entries gain `file` and `line`.

The CLI reads the routes from your app's own `Sources/Server/main.swift`, so an existing app keeps printing two columns until you update the `--routes` block there:

```swift
if arguments.contains("--routes") {
    for route in buildApp().routeList { print("\(route.method)\t\(route.path)\t\(route.file):\(route.line)") }
    exit(0)
}
```

Code that spelt out the old type of `routeList` or `Router.descriptions`, `[(method: String, path: String)]`, needs `[RouteDescription]` instead.
