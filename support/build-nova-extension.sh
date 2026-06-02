#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
extension_dir="$repo_root/editors/nova/Plume.novaextension"
grammar_dir="$extension_dir/TreeSitter/tree-sitter-plume"
parser_output="$extension_dir/Syntaxes/libtree-sitter-plume.dylib"
nova_app="${NOVA_APP_PATH:-/Applications/Nova.app}"
tree_sitter_cli_version="${TREE_SITTER_CLI_VERSION:-0.26.9}"

if [ ! -d "$grammar_dir" ]; then
  echo "Missing Tree-sitter grammar directory: $grammar_dir" >&2
  exit 1
fi

if [ ! -d "$nova_app" ]; then
  echo "Nova.app not found at $nova_app. Set NOVA_APP_PATH to the Nova.app used for SyntaxKit and validation." >&2
  exit 1
fi

syntaxkit_frameworks="$nova_app/Contents/Frameworks"
nova_cli="$nova_app/Contents/SharedSupport/nova"

if [ ! -d "$syntaxkit_frameworks/SyntaxKit.framework" ]; then
  echo "SyntaxKit.framework not found in $syntaxkit_frameworks" >&2
  exit 1
fi

(cd "$grammar_dir" && npx --yes "tree-sitter-cli@$tree_sitter_cli_version" generate)

clang -dynamiclib -fPIC -std=c11 -arch arm64 -arch x86_64 \
  -I "$grammar_dir/src" \
  "$grammar_dir/src/parser.c" \
  -F"$syntaxkit_frameworks" \
  -framework SyntaxKit \
  -rpath @loader_path/../Frameworks \
  -o "$parser_output"

codesign --sign - "$parser_output"
codesign --verify --verbose "$parser_output"

(cd "$grammar_dir" && npx --yes "tree-sitter-cli@$tree_sitter_cli_version" query \
  "$extension_dir/Queries/highlights.scm" \
  "$repo_root/support/nova-syntax-smoke.plume")

"$nova_cli" extension validate "$extension_dir"
