#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repository_dir=${script_dir:h}
tool_version=1.3.0
tool_archive_sha256=ad35efeca06baa1da2e5375932406cbc37a103b597fd1d1fa780968c2118c8d3
tool_cache_dir="$repository_dir/.build/mutation-tools/swift-mutation-testing-v$tool_version"
tool_archive="$tool_cache_dir/swift-mutation-testing-v$tool_version-macos.tar.gz"
tool_binary="$tool_cache_dir/swift-mutation-testing"
mutation_workspace_parent=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-mutation.XXXXXX")
mutation_workspace_parent=${mutation_workspace_parent:A}
mutation_workspace="$mutation_workspace_parent/repository"

cleanup() {
    if git -C "$repository_dir" worktree list --porcelain \
        | grep -Fqx "worktree $mutation_workspace"; then
        git -C "$repository_dir" worktree remove --force "$mutation_workspace" \
            || true
    fi
    rmdir "$mutation_workspace_parent" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$tool_cache_dir" "$repository_dir/build/mutation-testing"

if [[ ! -f "$tool_archive" ]]; then
    curl -fsSL --remove-on-error \
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

git -C "$repository_dir" worktree add --detach "$mutation_workspace" HEAD
rsync -a \
    --exclude .build \
    --exclude .git \
    --exclude .swift-mutation-testing-cache \
    --exclude build \
    "$repository_dir/" "$mutation_workspace/"

# The generated mutant schema is not production source and cannot satisfy the
# normal SwiftLint limits. Detach only the six build-tool plugin references in
# the disposable project; the standalone lint gate still checks real source.
mutation_project="$mutation_workspace/CodexBarIOS.xcodeproj/project.pbxproj"
sed -i '' -E \
    '/^[[:space:]]*21000000000000000000002[1-6] \/\* PBXTargetDependency \*\/,$/d' \
    "$mutation_project"

exclude_arguments=()
for source_file in "$mutation_workspace"/CodexBarIOS/Services/*.swift; do
    case "${source_file:t}" in
        AppReviewPromptPolicy.swift|DashboardUsageSorter.swift)
            ;;
        *)
            exclude_arguments+=(--exclude "${source_file#$mutation_workspace/}")
            ;;
    esac
done

# swift-mutation-testing expands each selected file into a large mutant schema.
# The disposable worktree keeps project-root discovery and mutation activation
# aligned while the normal repository-wide SwiftLint gate checks real source.
cd "$mutation_workspace"
mkdir -p build/mutation-testing
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    "$tool_binary" . "${exclude_arguments[@]}" "$@"
tool_status=$?
set -e

if [[ -d "$mutation_workspace/build/mutation-testing" ]]; then
    rsync -a \
        "$mutation_workspace/build/mutation-testing/" \
        "$repository_dir/build/mutation-testing/"
fi

exit "$tool_status"
