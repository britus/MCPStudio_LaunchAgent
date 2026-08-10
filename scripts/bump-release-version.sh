#!/usr/bin/env bash

set -euo pipefail

PROJECT_PATH=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: scripts/bump-release-version.sh [--project PATH] [--dry-run]

Increments the last component of MARKETING_VERSION and replaces
CURRENT_PROJECT_VERSION with a numeric UTC timestamp (yyyyMMddHHmmss).

Options:
  --project PATH  Xcode project or project.pbxproj.
                  Default: MCPStudioLaunchAgent.xcodeproj
  --dry-run       Print the next values without changing the project.
  --help          Show this help.

Environment:
  VERSION_BUMP_TIMESTAMP  Optional 14-digit UTC timestamp override for tests/CI.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)
            PROJECT_PATH="${2:?Missing value for --project}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_PATH=${PROJECT_PATH:-$ROOT_DIR/MCPStudioLaunchAgent.xcodeproj}

if [[ -d "$PROJECT_PATH" ]]; then
    PBXPROJ="$PROJECT_PATH/project.pbxproj"
else
    PBXPROJ="$PROJECT_PATH"
fi

[[ -f "$PBXPROJ" ]] || { echo "Xcode project file not found: $PBXPROJ" >&2; exit 1; }

marketing_values=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([0-9]+([.][0-9]+){1,2});$/\1/p' "$PBXPROJ" | sort -u)
marketing_count=$(printf '%s\n' "$marketing_values" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "$marketing_count" -ne 1 ]]; then
    echo "Expected one shared MARKETING_VERSION, found: ${marketing_values:-none}" >&2
    exit 1
fi

current_marketing="$marketing_values"
next_marketing=$(awk -F. '
    {
        $NF += 1
        for (i = 1; i <= NF; i++) {
            printf "%s%s", (i == 1 ? "" : "."), $i
        }
        printf "\n"
    }
' <<< "$current_marketing")

current_build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([0-9]+);$/\1/p' "$PBXPROJ" | sort -n | tail -n 1)
[[ -n "$current_build" ]] || { echo "CURRENT_PROJECT_VERSION was not found." >&2; exit 1; }

next_build=${VERSION_BUMP_TIMESTAMP:-$(date -u +%Y%m%d%H%M%S)}
[[ "$next_build" =~ ^[1-9][0-9]{13}$ ]] || {
    echo "The build timestamp must contain exactly 14 digits (yyyyMMddHHmmss)." >&2
    exit 1
}

if [[ ${#current_build} -lt ${#next_build} ]] ||
   { [[ ${#current_build} -eq ${#next_build} ]] && [[ "$current_build" < "$next_build" ]]; }; then
    :
else
    next_build=$((10#$current_build + 1))
fi

echo "Release version: $current_marketing -> $next_marketing"
echo "Build version:   $current_build -> $next_build"

if [[ "$DRY_RUN" -eq 1 ]]; then
    exit 0
fi

temporary_file=$(mktemp "$PBXPROJ.version.XXXXXX")
cleanup() {
    rm -f "$temporary_file"
}
trap cleanup EXIT

awk -v marketing="$next_marketing" -v build="$next_build" '
    /^[[:space:]]*MARKETING_VERSION = [0-9]+([.][0-9]+){1,2};$/ {
        sub(/MARKETING_VERSION = [^;]+;/, "MARKETING_VERSION = " marketing ";")
    }
    /^[[:space:]]*CURRENT_PROJECT_VERSION = [0-9]+;$/ {
        sub(/CURRENT_PROJECT_VERSION = [^;]+;/, "CURRENT_PROJECT_VERSION = " build ";")
    }
    { print }
' "$PBXPROJ" > "$temporary_file"

chmod "$(stat -f %Lp "$PBXPROJ")" "$temporary_file"
mv "$temporary_file" "$PBXPROJ"
trap - EXIT

remaining_marketing=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);$/\1/p' "$PBXPROJ" | sort -u)
remaining_build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);$/\1/p' "$PBXPROJ" | sort -u)
[[ "$remaining_marketing" == "$next_marketing" && "$remaining_build" == "$next_build" ]] || {
    echo "Version update verification failed." >&2
    exit 1
}
