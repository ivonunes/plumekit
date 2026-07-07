#!/usr/bin/env bash
#
# Proves the ORM's type safety is real: a wrong-type predicate must FAIL TO
# COMPILE. `Post.published` is a `Column<Post, Bool>`; `> 100` has no matching
# overload (Bool isn't Comparable, and 100 isn't Bool), so the build must fail.
#
# This is the compile-fail half of the query-builder contract — a passing build
# here would mean the type checker is NOT catching portability/type violations.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Sources/badpredicate"
cat > "$WORK/Package.swift" <<EOF
// swift-tools-version:6.2
import PackageDescription
let package = Package(
    name: "badpredicate",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT")],
    targets: [.executableTarget(name: "badpredicate", dependencies: [
        .product(name: "PlumeORM", package: "$(basename "$ROOT" | tr '[:upper:]' '[:lower:]')"),
    ])]
)
EOF

cat > "$WORK/Sources/badpredicate/main.swift" <<'EOF'
import PlumeORM

@Model
final class Post: Model {
    var id: Int
    var published = false
}

// WRONG: `published` is Bool — `> 100` must not type-check.
let bad = Post.published > 100
_ = bad
EOF

echo "==> attempting to compile a wrong-type predicate (must fail)…"
if swift build --package-path "$WORK" >"$WORK/out.log" 2>&1; then
  echo "FAIL: wrong-type predicate compiled — type safety is NOT enforced." >&2
  exit 1
fi

if grep -qiE "binary operator '>'|operator function '>'|cannot be applied|referencing operator" "$WORK/out.log"; then
  echo "OK: wrong-type predicate is rejected by the type checker (as required)."
else
  echo "NOTE: build failed, but not with the expected operator type error:" >&2
  tail -20 "$WORK/out.log" >&2
  exit 1
fi
