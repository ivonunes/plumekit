#!/usr/bin/env bash
#
# update-vendored.sh
#
# Checks the upstreams of the vendored ThirdParty/ dependencies and applies any
# newer release in place, printing one "name: old -> new" line per update.
# Prints nothing when everything is current. The weekly update-vendored.yml
# workflow runs this and turns the resulting diff into a PR; running it locally
# works the same way (inspect the result with git diff).
set -euo pipefail
cd "$(dirname "$0")/.."

# newer CURRENT CANDIDATE — true when CANDIDATE is a newer version
newer() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$2" ]
}

# sha3_256 FILE — empty output when no tool on this machine can compute it
sha3_256() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys; print(hashlib.sha3_256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
  else
    openssl dgst -sha3-256 -r "$1" 2>/dev/null | cut -d' ' -f1 || true
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- SQLite (ThirdParty/CSQLite) --------------------------------------------
# sqlite.org embeds machine-readable "PRODUCT,version,url,size,sha3" lines in
# its download page precisely so scripts can find the current amalgamation.
CURRENT="$(sed -n 's/.*SQLITE_VERSION[[:space:]]*"\([0-9.]*\)".*/\1/p' ThirdParty/CSQLite/include/sqlite3.h | head -n1)"
PRODUCT="$(curl -fsSL https://www.sqlite.org/download.html \
  | grep -o 'PRODUCT,[0-9.]*,[0-9]*/sqlite-amalgamation-[0-9]*\.zip,[0-9]*,[0-9a-f]*' | head -n1)"
VERSION="$(printf '%s' "$PRODUCT" | cut -d, -f2)"
RELURL="$(printf '%s' "$PRODUCT" | cut -d, -f3)"
SHA3="$(printf '%s' "$PRODUCT" | cut -d, -f5)"
if newer "$CURRENT" "$VERSION"; then
  curl -fsSL "https://www.sqlite.org/$RELURL" -o "$TMP/sqlite.zip"
  GOT="$(sha3_256 "$TMP/sqlite.zip")"
  if [ -n "$GOT" ] && [ "$GOT" != "$SHA3" ]; then
    echo "CSQLite: checksum mismatch for $RELURL (expected $SHA3, got $GOT)" >&2
    exit 1
  fi
  [ -n "$GOT" ] || echo "CSQLite: no SHA3-256 tool available, checksum not verified" >&2
  unzip -q "$TMP/sqlite.zip" -d "$TMP"
  cp "$TMP"/sqlite-amalgamation-*/sqlite3.c ThirdParty/CSQLite/sqlite3.c
  cp "$TMP"/sqlite-amalgamation-*/sqlite3.h ThirdParty/CSQLite/include/sqlite3.h
  AMALGAMATION="$(basename "$RELURL" .zip)"
  sed -i.bak \
    -e "s|^- Version: .*|- Version: $VERSION (\`$AMALGAMATION\`)|" \
    -e "s|^- Source: .*|- Source: https://www.sqlite.org/$RELURL|" \
    ThirdParty/CSQLite/README.md
  rm ThirdParty/CSQLite/README.md.bak
  echo "CSQLite: $CURRENT -> $VERSION"
fi

# --- zlib (ThirdParty/CZlib) ------------------------------------------------
# Deflate side only; the file set is whatever is already vendored, refreshed
# from the release tag.
CURRENT="$(sed -n 's/.*ZLIB_VERSION[[:space:]]*"\([0-9.]*\)".*/\1/p' ThirdParty/CZlib/include/zlib.h | head -n1)"
VERSION="$(git ls-remote --tags https://github.com/madler/zlib \
  | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -n1 | sed 's/^v//')"
if newer "$CURRENT" "$VERSION"; then
  curl -fsSL "https://github.com/madler/zlib/archive/refs/tags/v$VERSION.tar.gz" | tar -xz -C "$TMP"
  SRC="$TMP/zlib-$VERSION"
  for f in ThirdParty/CZlib/*.c ThirdParty/CZlib/*.h; do
    cp "$SRC/$(basename "$f")" "$f"
  done
  cp "$SRC/zlib.h" "$SRC/zconf.h" ThirdParty/CZlib/include/
  sed -i.bak "s|zlib [0-9.]* (https|zlib $VERSION (https|" ThirdParty/CZlib/README.md
  rm ThirdParty/CZlib/README.md.bak
  echo "CZlib: $CURRENT -> $VERSION"
fi
