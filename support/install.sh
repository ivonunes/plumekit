#!/bin/sh
set -eu

repo="ivonunes/plume"
version="latest"
prefix="/usr/local"
bin_dir=""

usage() {
    cat <<'USAGE'
Install Plume.

Usage:
  install.sh [--version VERSION] [--prefix PREFIX] [--bin-dir DIR]

Options:
  --version VERSION   Install a specific release tag or version, for example v1.0.0.
  --prefix PREFIX     Install under PREFIX/bin. Defaults to /usr/local.
  --bin-dir DIR       Install directly into DIR, overriding --prefix.
  --repo OWNER/REPO   Download from another GitHub repository.
  -h, --help          Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            version="${2:-}"
            [ -n "$version" ] || { echo "Missing value for --version" >&2; exit 1; }
            shift 2
            ;;
        --prefix)
            prefix="${2:-}"
            [ -n "$prefix" ] || { echo "Missing value for --prefix" >&2; exit 1; }
            shift 2
            ;;
        --bin-dir)
            bin_dir="${2:-}"
            [ -n "$bin_dir" ] || { echo "Missing value for --bin-dir" >&2; exit 1; }
            shift 2
            ;;
        --repo)
            repo="${2:-}"
            [ -n "$repo" ] || { echo "Missing value for --repo" >&2; exit 1; }
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

download() {
    url="$1"
    destination="$2"
    if command_exists curl; then
        curl -fsSL "$url" -o "$destination"
    elif command_exists wget; then
        wget -qO "$destination" "$url"
    else
        echo "Plume install requires curl or wget." >&2
        exit 1
    fi
}

download_stdout() {
    url="$1"
    if command_exists curl; then
        curl -fsSL "$url"
    elif command_exists wget; then
        wget -qO- "$url"
    else
        echo "Plume install requires curl or wget." >&2
        exit 1
    fi
}

detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) echo "linux" ;;
        *)
            echo "Unsupported operating system: $(uname -s)" >&2
            exit 1
            ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo "arm64" ;;
        x86_64|amd64) echo "x86_64" ;;
        *)
            echo "Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac
}

latest_version() {
    download_stdout "https://api.github.com/repos/$repo/releases/latest" |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        sed -n '1p'
}

if [ "$version" = "latest" ]; then
    version="$(latest_version)"
    [ -n "$version" ] || { echo "Could not determine latest Plume release." >&2; exit 1; }
fi

case "$version" in
    v*) tag="$version" ;;
    *) tag="v$version" ;;
esac

[ -n "$bin_dir" ] || bin_dir="$prefix/bin"

platform="$(detect_platform)"
arch="$(detect_arch)"
archive="plume-$tag-$platform-$arch.tar.gz"
checksums="plume-$tag-SHA256SUMS"
base_url="https://github.com/$repo/releases/download/$tag"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/plume-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "Downloading Plume $tag for $platform-$arch..."
download "$base_url/$archive" "$tmp/$archive"

if download "$base_url/$checksums" "$tmp/SHA256SUMS"; then
    (
        cd "$tmp"
        grep " $archive\$" SHA256SUMS > "$archive.sha256"
        if command_exists sha256sum; then
            sha256sum -c "$archive.sha256"
        else
            shasum -a 256 -c "$archive.sha256"
        fi
    )
else
    echo "Warning: could not download SHA256SUMS; installing without checksum verification." >&2
fi

tar -xzf "$tmp/$archive" -C "$tmp"
mkdir -p "$bin_dir"

if command_exists install; then
    install -m 0755 "$tmp/plume" "$bin_dir/plume"
else
    cp "$tmp/plume" "$bin_dir/plume"
    chmod 0755 "$bin_dir/plume"
fi

echo "Installed Plume to $bin_dir/plume"
"$bin_dir/plume" version
