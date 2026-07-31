#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repository_dir=${script_dir:h}
tool_version=1.3.0
tool_archive_sha256=ad35efeca06baa1da2e5375932406cbc37a103b597fd1d1fa780968c2118c8d3
tool_cache_dir="$repository_dir/.build/mutation-tools/swift-mutation-testing-v$tool_version"
tool_archive="$tool_cache_dir/swift-mutation-testing-v$tool_version-macos.tar.gz"
tool_binary="$tool_cache_dir/swift-mutation-testing"
mutation_workspace_key=$(print -rn -- "$repository_dir" | cksum | awk '{print $1}')
mutation_workspace_parent="${TMPDIR:-/tmp}/codexbar-mutation.$mutation_workspace_key"
mutation_workspace_parent=${mutation_workspace_parent:A}
mutation_workspace="$mutation_workspace_parent/repository"
mutation_lock="$mutation_workspace_parent.lock"
lock_acquired=false
requested_report_paths=()

arguments=("$@")
for ((argument_index = 1; argument_index <= ${#arguments}; argument_index++)); do
    argument=${arguments[$argument_index]}
    case "$argument" in
        --output|--html-output|--sonar-output)
            ((argument_index++))
            if ((argument_index <= ${#arguments})); then
                requested_report_paths+=("${arguments[$argument_index]}")
            fi
            ;;
        --output=*|--html-output=*|--sonar-output=*)
            requested_report_paths+=("${argument#*=}")
            ;;
    esac
done

for report_path in "${requested_report_paths[@]}"; do
    if [[ "$report_path" != /* ]]; then
        report_source="$mutation_workspace/$report_path"
        report_source=${report_source:A}
        if [[ "$report_source" != "$mutation_workspace/"* ]]; then
            print -u2 "Relative report path must stay within the project: $report_path"
            exit 1
        fi
    fi
done

sync_mutation_cache() {
    if [[ -d "$mutation_workspace/.swift-mutation-testing-cache" ]]; then
        mkdir -p "$repository_dir/.swift-mutation-testing-cache"
        rsync -a --delete \
            "$mutation_workspace/.swift-mutation-testing-cache/" \
            "$repository_dir/.swift-mutation-testing-cache/"
    fi
}

sync_mutation_reports() {
    if [[ -d "$mutation_workspace/build/mutation-testing" ]]; then
        rsync -a \
            "$mutation_workspace/build/mutation-testing/" \
            "$repository_dir/build/mutation-testing/"
    fi
    for report_path in "${requested_report_paths[@]}"; do
        [[ "$report_path" == /* ]] && continue
        local report_source="$mutation_workspace/$report_path"
        local report_destination="$repository_dir/$report_path"
        if [[ -f "$report_source" ]]; then
            mkdir -p "${report_destination:h}"
            rsync -a "$report_source" "$report_destination"
        fi
    done
}

cleanup() {
    [[ "$lock_acquired" == true ]] || return
    local artifacts_saved=true
    if ! sync_mutation_reports; then
        artifacts_saved=false
        print -u2 "Could not save mutation reports; preserving $mutation_workspace for recovery."
    fi
    if ! sync_mutation_cache; then
        artifacts_saved=false
        print -u2 "Could not save the mutation cache; preserving $mutation_workspace for recovery."
    fi
    if [[ "$artifacts_saved" == true ]]; then
        if git -C "$repository_dir" worktree list --porcelain \
            | grep -Fqx "worktree $mutation_workspace"; then
            git -C "$repository_dir" worktree remove --force "$mutation_workspace" \
                || true
        fi
        rmdir "$mutation_workspace_parent" 2>/dev/null || true
    fi
    rm -f "$mutation_lock/pid"
    rmdir "$mutation_lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_mutation_lock() {
    mkdir "$mutation_lock" 2>/dev/null && return 0

    lock_owner=unknown
    if [[ -r "$mutation_lock/pid" ]]; then
        lock_owner=$(<"$mutation_lock/pid")
    fi
    if [[ "$lock_owner" == <-> ]] && ! kill -0 "$lock_owner" 2>/dev/null; then
        rm -f "$mutation_lock/pid"
        rmdir "$mutation_lock" 2>/dev/null || return 1
        mkdir "$mutation_lock" 2>/dev/null && return 0
    fi
    return 1
}

if ! acquire_mutation_lock; then
    lock_owner=unknown
    if [[ -r "$mutation_lock/pid" ]]; then
        lock_owner=$(<"$mutation_lock/pid")
    fi
    print -u2 "Another mutation pilot owns $mutation_lock (PID $lock_owner); refusing to disturb it."
    exit 1
fi
lock_acquired=true
print -r -- "$$" > "$mutation_lock/pid"

if git -C "$repository_dir" worktree list --porcelain \
    | grep -Fqx "worktree $mutation_workspace"; then
    sync_mutation_cache
    git -C "$repository_dir" worktree remove --force "$mutation_workspace"
    rmdir "$mutation_workspace_parent" 2>/dev/null || true
fi
if [[ -e "$mutation_workspace_parent" ]]; then
    print -u2 "Mutation workspace already exists but is not a registered worktree: $mutation_workspace_parent"
    exit 1
fi
mkdir -p "$mutation_workspace_parent"

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
    --delete \
    --exclude .build \
    --exclude .git \
    --exclude .swift-mutation-testing-cache \
    --exclude build \
    "$repository_dir/" "$mutation_workspace/"

if [[ -d "$repository_dir/.swift-mutation-testing-cache" ]]; then
    mkdir -p "$mutation_workspace/.swift-mutation-testing-cache"
    rsync -a --delete \
        "$repository_dir/.swift-mutation-testing-cache/" \
        "$mutation_workspace/.swift-mutation-testing-cache/"
fi

# The generated mutant schema is not production source and cannot satisfy the
# normal SwiftLint limits. Detach only the six build-tool plugin references in
# the disposable project; the standalone lint gate still checks real source.
mutation_project="$mutation_workspace/CodexBarIOS.xcodeproj/project.pbxproj"
sed -i '' -E \
    '/^[[:space:]]*21000000000000000000002[1-6] \/\* PBXTargetDependency \*\/,[[:space:]]*$/d' \
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
for report_path in "${requested_report_paths[@]}"; do
    if [[ "$report_path" != /* ]]; then
        mkdir -p "${report_path:h}"
    fi
done
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    "$tool_binary" . "${exclude_arguments[@]}" "$@"
tool_status=$?
set -e

exit "$tool_status"
