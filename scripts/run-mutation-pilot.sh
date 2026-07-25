#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repository_dir=${script_dir:h}
tool_version=1.3.0
tool_archive_sha256=ad35efeca06baa1da2e5375932406cbc37a103b597fd1d1fa780968c2118c8d3
tool_cache_dir="$repository_dir/.build/mutation-tools/swift-mutation-testing-v$tool_version"
tool_archive="$tool_cache_dir/swift-mutation-testing-v$tool_version-macos.tar.gz"
tool_binary="$tool_cache_dir/swift-mutation-testing"

mkdir -p "$tool_cache_dir" "$repository_dir/build/mutation-testing"

if [[ ! -f "$tool_archive" ]]; then
    curl -fsSL \
        "https://github.com/ericodx/swift-mutation-testing/releases/download/v$tool_version/swift-mutation-testing-v$tool_version-macos.tar.gz" \
        -o "$tool_archive"
fi

printf '%s  %s\n' "$tool_archive_sha256" "$tool_archive" | shasum -a 256 -c -

if [[ ! -x "$tool_binary" ]]; then
    tar -xzf "$tool_archive" -C "$tool_cache_dir"
fi

if [[ "$("$tool_binary" --version)" != "swift-mutation-testing $tool_version "* ]]; then
    echo "Expected swift-mutation-testing $tool_version." >&2
    exit 1
fi

exclude_arguments=()
for source_file in "$repository_dir"/CodexBarIOS/Services/*.swift; do
    case "${source_file:t}" in
        DashboardUsageSorter.swift)
            ;;
        *)
            exclude_arguments+=(--exclude "${source_file#$repository_dir/}")
            ;;
    esac
done

cd "$repository_dir"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    "$tool_binary" . "${exclude_arguments[@]}" "$@"
