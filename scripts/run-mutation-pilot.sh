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
report_manifest="$mutation_workspace_parent/report-paths"
cache_staging_marker="$mutation_workspace_parent/cache-staging-complete"
lock_acquired=false
tool_pid=
requested_report_paths=()
configured_report_paths=()

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

strip_yaml_comment() {
    local value="$1"
    local result=""
    local quote=""
    local escaped=false
    local character
    for ((value_index = 1; value_index <= ${#value}; value_index++)); do
        character=${value[$value_index]}
        if [[ -n "$quote" ]]; then
            if [[ "$quote" == \" && "$escaped" == true ]]; then
                escaped=false
            elif [[ "$quote" == \" && "$character" == \\ ]]; then
                escaped=true
            elif [[ "$character" == "$quote" ]]; then
                quote=""
            fi
        elif [[ "$character" == \" || "$character" == \' ]]; then
            quote="$character"
        elif [[ "$character" == \# ]]; then
            if ((value_index == 1)) \
                || [[ "${value[$((value_index - 1))]}" == [[:space:]] ]]; then
                break
            fi
        fi
        result+="$character"
    done
    print -rn -- "$result"
}

decode_yaml_quoted_scalar() {
    local value="$1"
    if (( ${#value} < 2 )); then
        print -rn -- "$value"
        return
    fi

    local quote=${value[1]}
    local decoded=""
    local character
    if [[ "$quote" == \' && "${value[-1]}" != \' ]] \
        || [[ "$quote" == \" && "${value[-1]}" != \" ]]; then
        print -u2 "Multiline YAML report paths are not supported."
        return 1
    fi
    if [[ "$quote" == \' ]]; then
        value=${value[2,-2]}
        for ((value_index = 1; value_index <= ${#value}; value_index++)); do
            character=${value[$value_index]}
            if [[ "$character" != \' ]]; then
                decoded+="$character"
                continue
            fi
            if ((value_index == ${#value})) \
                || [[ "${value[$((value_index + 1))]}" != \' ]]; then
                print -u2 "Invalid apostrophe escape in YAML report path."
                return 1
            fi
            decoded+="'"
            ((value_index++))
        done
        print -rn -- "$decoded"
        return
    fi
    if [[ "$quote" != \" || "${value[-1]}" != \" ]]; then
        print -rn -- "$value"
        return
    fi

    value=${value[2,-2]}
    local escape_character hex_digits
    local code_point
    local escape_width
    for ((value_index = 1; value_index <= ${#value}; value_index++)); do
        character=${value[$value_index]}
        if [[ "$character" != \\ ]]; then
            decoded+="$character"
            continue
        fi

        ((value_index++))
        if ((value_index > ${#value})); then
            print -u2 "Invalid trailing escape in YAML report path."
            return 1
        fi
        escape_character=${value[$value_index]}
        case "$escape_character" in
            0)
                print -u2 "YAML report paths cannot contain a null byte."
                return 1
                ;;
            n|r)
                print -u2 "YAML report paths cannot contain line breaks."
                return 1
                ;;
            a|b|t|v|f|e|\\)
                decoded+="\\$escape_character"
                ;;
            \"|/)
                decoded+="$escape_character"
                ;;
            ' ')
                decoded+=' '
                ;;
            N)
                decoded+="\\u0085"
                ;;
            _)
                decoded+="\\u00a0"
                ;;
            L)
                decoded+="\\u2028"
                ;;
            P)
                decoded+="\\u2029"
                ;;
            x|u|U)
                case "$escape_character" in
                    x) escape_width=2 ;;
                    u) escape_width=4 ;;
                    U) escape_width=8 ;;
                esac
                hex_digits=${value[$((value_index + 1)),$((value_index + escape_width))]}
                if (( ${#hex_digits} != escape_width )) \
                    || [[ "$hex_digits" == *[^[:xdigit:]]* ]]; then
                    print -u2 "Invalid Unicode escape in YAML report path."
                    return 1
                fi
                ((code_point = 16#$hex_digits))
                if ((code_point == 0 || code_point == 0x0a || code_point == 0x0d \
                    || code_point > 0x10ffff \
                    || (code_point >= 0xd800 && code_point <= 0xdfff))); then
                    print -u2 "Invalid Unicode scalar in YAML report path."
                    return 1
                fi
                if [[ "$escape_character" == x ]]; then
                    decoded+="\\u00$hex_digits"
                else
                    decoded+="\\$escape_character$hex_digits"
                fi
                ((value_index += escape_width))
                ;;
            *)
                print -u2 "Unsupported escape in YAML report path: \\$escape_character"
                return 1
                ;;
        esac
    done
    printf '%b' "$decoded"
}

split_yaml_mapping_entry() {
    local value="$1"
    local quote=""
    local escaped=false
    local character
    for ((value_index = 1; value_index <= ${#value}; value_index++)); do
        character=${value[$value_index]}
        if [[ -n "$quote" ]]; then
            if [[ "$quote" == \" && "$escaped" == true ]]; then
                escaped=false
            elif [[ "$quote" == \" && "$character" == \\ ]]; then
                escaped=true
            elif [[ "$character" == "$quote" ]]; then
                quote=""
            fi
        elif [[ "$character" == \" || "$character" == \' ]]; then
            quote="$character"
        elif [[ "$character" == : ]]; then
            reply=("${value[1,$((value_index - 1))]}" "${value[$((value_index + 1)),-1]}")
            return
        fi
    done
    return 1
}

collect_single_line_yaml_report_paths() {
    local configuration_path="$1"
    local report_scalar_active=false
    local root_indent=-1
    local report_key_indent=-1
    local line indentation trimmed_line marker_candidate mapping_key scalar
    local indent_width
    while IFS= read -r line || [[ -n "$line" ]]; do
        indentation=${line%%[![:space:]]*}
        trimmed_line=${line#"$indentation"}
        if [[ "$report_scalar_active" == true ]]; then
            if [[ -z "$trimmed_line" || "${trimmed_line[1]}" == \# ]]; then
                continue
            fi
            indent_width=${#indentation}
            if ((indent_width > report_key_indent)); then
                print -u2 "Multiline YAML report paths are not supported."
                return 1
            fi
            report_scalar_active=false
        fi

        marker_candidate=$(strip_yaml_comment "$trimmed_line")
        marker_candidate="${marker_candidate%"${marker_candidate##*[![:space:]]}"}"
        if [[ -z "$trimmed_line" || "${trimmed_line[1]}" == \# \
            || "$marker_candidate" == --- || "$marker_candidate" == ... \
            || "${trimmed_line[1]}" == % ]]; then
            continue
        fi
        indent_width=${#indentation}
        if ((root_indent < 0)); then
            root_indent=$indent_width
        fi
        ((indent_width == root_indent)) || continue

        split_yaml_mapping_entry "$trimmed_line" || continue
        mapping_key=${reply[1]}
        mapping_key="${mapping_key#"${mapping_key%%[![:space:]]*}"}"
        mapping_key="${mapping_key%"${mapping_key##*[![:space:]]}"}"
        mapping_key=$(decode_yaml_quoted_scalar "$mapping_key")
        if [[ "$mapping_key" == output || "$mapping_key" == html-output \
            || "$mapping_key" == sonar-output ]]; then
            report_scalar_active=true
            report_key_indent=$indent_width
            scalar=${reply[2]}
            scalar=$(strip_yaml_comment "$scalar")
            scalar="${scalar#"${scalar%%[![:space:]]*}"}"
            scalar="${scalar%"${scalar##*[![:space:]]}"}"
            if [[ "${scalar[1]}" == \| || "${scalar[1]}" == \> ]]; then
                print -u2 "YAML block scalars are not supported for report paths."
                return 1
            fi
            if [[ "${scalar[1]}" == \& || "${scalar[1]}" == \* \
                || "${scalar[1]}" == \! ]]; then
                print -u2 "YAML anchors, aliases, and tags are not supported for report paths."
                return 1
            fi
            scalar=$(decode_yaml_quoted_scalar "$scalar")
            [[ -n "$scalar" ]] && configured_report_paths+=("$scalar")
        fi
    done < "$configuration_path"
}

if [[ -r "$repository_dir/.swift-mutation-testing.yml" ]]; then
    collect_single_line_yaml_report_paths "$repository_dir/.swift-mutation-testing.yml"
fi

preserved_report_paths=("${configured_report_paths[@]}" "${requested_report_paths[@]}")
for report_path in "${preserved_report_paths[@]}"; do
    if [[ "$report_path" == *$'\n'* || "$report_path" == *$'\r'* ]]; then
        print -u2 "Report paths cannot contain line breaks."
        exit 1
    fi
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
    [[ -f "$cache_staging_marker" ]] || return 0
    if [[ -d "$mutation_workspace/.swift-mutation-testing-cache" ]]; then
        mkdir -p "$repository_dir/.swift-mutation-testing-cache" || return 1
        rsync -a --delete \
            "$mutation_workspace/.swift-mutation-testing-cache/" \
            "$repository_dir/.swift-mutation-testing-cache/" || return 1
    fi
}

sync_mutation_reports() {
    local reports_saved=true
    if [[ -d "$mutation_workspace/build/mutation-testing" ]]; then
        if ! mkdir -p "$repository_dir/build/mutation-testing" \
            || ! rsync -a \
            "$mutation_workspace/build/mutation-testing/" \
            "$repository_dir/build/mutation-testing/"; then
            reports_saved=false
        fi
    fi

    local saved_report_paths=()
    if [[ -r "$report_manifest" ]]; then
        while IFS= read -r report_path; do
            [[ -n "$report_path" ]] && saved_report_paths+=("$report_path")
        done < "$report_manifest"
    else
        saved_report_paths=("${preserved_report_paths[@]}")
    fi

    for report_path in "${saved_report_paths[@]}"; do
        [[ "$report_path" == /* ]] && continue
        local report_source="$mutation_workspace/$report_path"
        local report_destination="$repository_dir/$report_path"
        if [[ -f "$report_source" ]]; then
            if ! mkdir -p "${report_destination:h}" \
                || ! rsync -a "$report_source" "$report_destination"; then
                reports_saved=false
            fi
        fi
    done
    [[ "$reports_saved" == true ]]
}

cleanup() {
    local exit_status=$?
    trap - EXIT
    [[ "$lock_acquired" == true ]] || exit "$exit_status"
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
        rm -f "$report_manifest" "$cache_staging_marker"
        rmdir "$mutation_workspace_parent" 2>/dev/null || true
    fi
    rm -f "$mutation_lock/pid" "$mutation_lock/pid.next"
    rmdir "$mutation_lock" 2>/dev/null || true
    if [[ "$artifacts_saved" != true && "$exit_status" -eq 0 ]]; then
        exit_status=1
    fi
    exit "$exit_status"
}
trap cleanup EXIT

forward_signal() {
    local signal_name="$1"
    local exit_status="$2"
    trap - "$signal_name"
    if [[ "$tool_pid" == <-> ]] && kill -0 "$tool_pid" 2>/dev/null; then
        kill -"$signal_name" "$tool_pid" 2>/dev/null || true
        wait "$tool_pid" 2>/dev/null || true
    fi
    exit "$exit_status"
}
trap 'forward_signal INT 130' INT
trap 'forward_signal TERM 143' TERM

acquire_mutation_lock() {
    mkdir "$mutation_lock" 2>/dev/null && return 0

    [[ -r "$mutation_lock/pid" ]] || return 1
    local recorded_owner=false
    local lock_owner_pid
    while IFS= read -r lock_owner_pid; do
        [[ "$lock_owner_pid" == <-> ]] || continue
        recorded_owner=true
        kill -0 "$lock_owner_pid" 2>/dev/null && return 1
    done < "$mutation_lock/pid"
    [[ "$recorded_owner" == true ]] || return 1
    if git -C "$repository_dir" worktree list --porcelain \
        | grep -Fqx "worktree $mutation_workspace" \
        && lsof -a -d cwd "$mutation_workspace" >/dev/null 2>&1; then
        return 1
    fi
    rm -f "$mutation_lock/pid" "$mutation_lock/pid.next"
    rmdir "$mutation_lock" 2>/dev/null || return 1
    mkdir "$mutation_lock" 2>/dev/null
}

if ! acquire_mutation_lock; then
    lock_owner=unknown
    if [[ -r "$mutation_lock/pid" ]]; then
        lock_owner=$(paste -sd, "$mutation_lock/pid")
    fi
    print -u2 "Another mutation pilot owns $mutation_lock (PID $lock_owner); refusing to disturb it."
    exit 1
fi
lock_acquired=true
print -r -- "$$" > "$mutation_lock/pid"

if git -C "$repository_dir" worktree list --porcelain \
    | grep -Fqx "worktree $mutation_workspace"; then
    recovered_artifacts_saved=true
    sync_mutation_reports || recovered_artifacts_saved=false
    sync_mutation_cache || recovered_artifacts_saved=false
    if [[ "$recovered_artifacts_saved" != true ]]; then
        print -u2 "Could not recover mutation artifacts; preserving $mutation_workspace for recovery."
        exit 1
    fi
    git -C "$repository_dir" worktree remove --force "$mutation_workspace"
    rm -f "$report_manifest" "$cache_staging_marker"
    rmdir "$mutation_workspace_parent" 2>/dev/null || true
fi
if [[ -e "$mutation_workspace_parent" ]]; then
    print -u2 "Mutation workspace already exists but is not a registered worktree: $mutation_workspace_parent"
    exit 1
fi
mkdir -p "$mutation_workspace_parent"
: > "$report_manifest"
for report_path in "${preserved_report_paths[@]}"; do
    print -r -- "$report_path" >> "$report_manifest"
done

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
: > "$cache_staging_marker"

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
for report_path in "${preserved_report_paths[@]}"; do
    if [[ "$report_path" != /* ]]; then
        mkdir -p "${report_path:h}"
    fi
done
set +e
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    "$tool_binary" . "${exclude_arguments[@]}" "$@" &
tool_pid=$!
{
    print -r -- "$$"
    print -r -- "$tool_pid"
} > "$mutation_lock/pid.next"
mv -f "$mutation_lock/pid.next" "$mutation_lock/pid"
wait "$tool_pid"
tool_status=$?
tool_pid=
set -e

exit "$tool_status"
