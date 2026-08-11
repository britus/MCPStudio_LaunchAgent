#!/usr/bin/env bash

set -euo pipefail

SCHEME="MCPStudioLaunchAgent"
CONFIGURATION="Release"
EXECUTABLE_NAME="MCPStudioLaunchAgent"
COMPONENT_IDENTIFIER="org.eof.tools.MCPStudio.LaunchAgent"
PACKAGE_IDENTIFIER="org.eof.tools.MCPStudio.LaunchAgent.pkg"
LAUNCHD_LABEL="org.eof.tools.MCPStudio.LaunchAgent"
MACH_SERVICE="group.org.eof.apps.mcpstudio.agent"
DISPLAY_NAME="EoF MCP Studio Launch Agent"
APPLE_ACC_ID="${GLOBAL_APPLE_ID:-}"
APPLE_ACC_PASSWORD="${GLOBAL_APPLE_PASSWORD:-}"
NOTARIZATION_APP_PASSWORD="${GLOBAL_NOTARIZAION_PASSWORD:-}"
TEAM_ID="${GLOBAL_TEAM_ID:-}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-15.6}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"
BUILD_ARCHITECTURES="${BUILD_ARCHITECTURES:-arm64 x86_64}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-eof-mcp-studio-launchagent-notary}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCPSTUDIO_WORKSPACE_DIR="$(cd "$ROOT_DIR/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/MCPStudioLaunchAgent.xcodeproj"
PACKAGING_DIR="$ROOT_DIR/Packaging"
PLIST_TEMPLATE="$ROOT_DIR/LaunchAgents/$LAUNCHD_LABEL.plist.template"
ENTITLEMENTS_PATH="$ROOT_DIR/MCPStudioLaunchAgent.entitlements"
BUILD_ROOT="$ROOT_DIR/Build/Package"
DERIVED_DATA_DIR="$BUILD_ROOT/DerivedData"
INTERMEDIATE_DIR="$BUILD_ROOT/Intermediate"
PAYLOAD_ROOT="$INTERMEDIATE_DIR/Payload"
COMPONENT_PACKAGE="$INTERMEDIATE_DIR/MCPStudioLaunchAgent-component.pkg"
OUTPUT_DIR="$BUILD_ROOT/Artifacts"
DEFAULT_RELEASE_DIR="$MCPSTUDIO_WORKSPACE_DIR/MCPStudio_public/releases/launchagent/artifacts"

INSTALL_SUPPORT_DIR="/Library/Application Support/$COMPONENT_IDENTIFIER"
INSTALL_BINARY_PATH="$INSTALL_SUPPORT_DIR/$EXECUTABLE_NAME"
INSTALL_PLIST_PATH="/Library/LaunchAgents/$LAUNCHD_LABEL.plist"

VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
BINARY_PATH=""
APPLICATION_IDENTITY="${APPLICATION_IDENTITY:-}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
RELEASE_DIR="${LAUNCHAGENT_RELEASE_DIR:-${DEPLOY_DIR:-$DEFAULT_RELEASE_DIR}}"
RELEASE_DIR_EXPLICIT=0
if [[ -n "${LAUNCHAGENT_RELEASE_DIR:-${DEPLOY_DIR:-}}" ]]; then
    RELEASE_DIR_EXPLICIT=1
fi
SKIP_BUILD=0
SKIP_RELEASE_VERSION_BUMP="${SKIP_RELEASE_VERSION_BUMP:-0}"
UNSIGNED=0
SKIP_NOTARIZATION=0
SKIP_LOCAL_RELEASE=0

usage() {
    cat <<'EOF'
Usage: scripts/build-pkg.sh [options]

Builds the EoF MCP Studio Launch Agent and creates a deployment-ready macOS
installer package. A signed and notarized production package is copied into the
local MCPStudio_public release mirror; this script never uploads it.

Options:
  --version <value>                 Require this embedded release version.
  --build-number <value>            Require this embedded build number.
  --architectures <list>            Space-separated architectures (default: arm64 x86_64).
  --binary-path <path>              Package an existing binary; implies --skip-build.
  --application-identity <identity> Developer ID Application identity.
  --installer-identity <identity>   Developer ID Installer identity.
  --keychain-profile <name>         notarytool keychain profile.
  --release-dir <path>              Override the local Launch Agent release directory.
  --deploy-dir <path>               Legacy alias for --release-dir.
  --no-local-release                Do not copy the final package to the local mirror.
  --skip-build                      Reuse the binary from DerivedData.
  --skip-version-bump               Keep the current Xcode project versions.
  --skip-notarization               Build and sign without notarizing.
  --unsigned                        Local validation package; no signing or notarization.
  -h, --help                        Show this help.

Environment equivalents:
  VERSION, BUILD_NUMBER, BUILD_ARCHITECTURES, APPLICATION_IDENTITY,
  INSTALLER_IDENTITY, NOTARY_KEYCHAIN_PROFILE, LAUNCHAGENT_RELEASE_DIR,
  DEPLOY_DIR (legacy), RELEASE_CHANNEL, MINIMUM_SYSTEM_VERSION.
  SKIP_RELEASE_VERSION_BUMP keeps the current project versions when set to 1.

Signing/notarization defaults:
  GLOBAL_APPLE_ID              Apple account id/email for notarytool.
  GLOBAL_APPLE_PASSWORD        Fallback app-specific password for notarytool.
  GLOBAL_NOTARIZAION_PASSWORD  Preferred app-specific notarization password.
  GLOBAL_TEAM_ID               Apple Developer Team ID.

Notarization credentials are read from an existing keychain profile. If it is
missing, the GLOBAL_* values above are used to create it.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

read_build_setting() {
    local key="$1"
    xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
        | awk -F ' = ' -v key="$key" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }'
}

resolve_identity() {
    local kind="$1" requested="$2" policy="$3" resolved=""
    if [[ -n "$requested" ]]; then
        security find-identity -v -p "$policy" | grep -F "\"$requested\"" >/dev/null \
            || die "$kind identity not found in keychain: $requested"
        printf '%s\n' "$requested"
        return
    fi
    resolved="$(security find-identity -v -p "$policy" \
        | grep -F "($TEAM_ID)" \
        | sed -n "s/.*\"\(Developer ID $kind:.*\)\"/\1/p" | head -n 1)"
    [[ -n "$resolved" ]] || die "no Developer ID $kind identity found"
    printf '%s\n' "$resolved"
}

prepare_notary_profile() {
    if xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        return
    fi
    local apple_password="$NOTARIZATION_APP_PASSWORD"
    [[ -n "$apple_password" ]] || apple_password="$APPLE_ACC_PASSWORD"
    [[ -n "$APPLE_ACC_ID" ]] || die "notary profile missing and GLOBAL_APPLE_ID is unset"
    [[ -n "$TEAM_ID" ]] || die "notary profile missing and GLOBAL_TEAM_ID is unset"
    [[ -n "$apple_password" ]] \
        || die "notary profile missing and GLOBAL_NOTARIZAION_PASSWORD / GLOBAL_APPLE_PASSWORD are unset"
    xcrun notarytool store-credentials "$NOTARY_KEYCHAIN_PROFILE" \
        --apple-id "$APPLE_ACC_ID" --team-id "$TEAM_ID" --password "$apple_password"
}

notarize_package() {
    local package_path="$1" result_plist="$INTERMEDIATE_DIR/notary-result.plist"
    local submission_id="" status=""
    prepare_notary_profile
    xcrun notarytool submit "$package_path" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
        --wait --output-format plist > "$result_plist"
    submission_id="$(plutil -extract id raw -o - "$result_plist" 2>/dev/null || true)"
    status="$(plutil -extract status raw -o - "$result_plist" 2>/dev/null || true)"
    if [[ "$status" != "Accepted" ]]; then
        if [[ -n "$submission_id" ]]; then
            xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
                "$INTERMEDIATE_DIR/notary-log.json" || true
        fi
        die "notarization failed with status: ${status:-unknown}"
    fi
    xcrun stapler staple "$package_path"
    xcrun stapler validate "$package_path"
}

copy_release_package() {
    local source_path="$1" destination_path="$RELEASE_DIR/$(basename "$1")"
    if [[ -e "$destination_path" ]]; then
        local source_hash destination_hash
        source_hash="$(shasum -a 256 "$source_path" | awk '{print $1}')"
        destination_hash="$(shasum -a 256 "$destination_path" | awk '{print $1}')"
        [[ "$source_hash" == "$destination_hash" ]] \
            || die "refusing to overwrite different artifact: $destination_path"
        return
    fi
    install -m 0644 "$source_path" "$destination_path"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || die "--version requires a value"; VERSION="$2"; shift 2 ;;
        --build-number) [[ $# -ge 2 ]] || die "--build-number requires a value"; BUILD_NUMBER="$2"; shift 2 ;;
        --architectures) [[ $# -ge 2 ]] || die "--architectures requires a value"; BUILD_ARCHITECTURES="$2"; shift 2 ;;
        --binary-path) [[ $# -ge 2 ]] || die "--binary-path requires a value"; BINARY_PATH="$2"; SKIP_BUILD=1; shift 2 ;;
        --application-identity) [[ $# -ge 2 ]] || die "--application-identity requires a value"; APPLICATION_IDENTITY="$2"; shift 2 ;;
        --installer-identity) [[ $# -ge 2 ]] || die "--installer-identity requires a value"; INSTALLER_IDENTITY="$2"; shift 2 ;;
        --keychain-profile) [[ $# -ge 2 ]] || die "--keychain-profile requires a value"; NOTARY_KEYCHAIN_PROFILE="$2"; shift 2 ;;
        --release-dir) [[ $# -ge 2 ]] || die "--release-dir requires a value"; RELEASE_DIR="$2"; RELEASE_DIR_EXPLICIT=1; shift 2 ;;
        --deploy-dir) [[ $# -ge 2 ]] || die "--deploy-dir requires a value"; RELEASE_DIR="$2"; RELEASE_DIR_EXPLICIT=1; shift 2 ;;
        --no-local-release) SKIP_LOCAL_RELEASE=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-version-bump) SKIP_RELEASE_VERSION_BUMP=1; shift ;;
        --skip-notarization) SKIP_NOTARIZATION=1; shift ;;
        --unsigned) UNSIGNED=1; SKIP_NOTARIZATION=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

for command_name in xcodebuild xcrun pkgbuild productbuild plutil lipo otool shasum xmllint; do
    require_command "$command_name"
done

[[ -d "$PROJECT_PATH" ]] || die "Xcode project not found: $PROJECT_PATH"
[[ -f "$PLIST_TEMPLATE" ]] || die "LaunchAgent plist template not found: $PLIST_TEMPLATE"
[[ -f "$ENTITLEMENTS_PATH" ]] || die "LaunchAgent entitlements not found: $ENTITLEMENTS_PATH"
[[ -f "$PACKAGING_DIR/Distribution.xml" ]] || die "Distribution.xml not found"
[[ -f "$PACKAGING_DIR/Welcome.html" ]] || die "Welcome.html not found"
[[ -f "$PACKAGING_DIR/Conclusion.html" ]] || die "Conclusion.html not found"
[[ -x "$PACKAGING_DIR/Scripts/postinstall" ]] || die "postinstall script is missing or not executable"
[[ -x "$ROOT_DIR/scripts/bump-release-version.sh" ]] || die "version bump script is missing or not executable"

REQUESTED_VERSION="$VERSION"
REQUESTED_BUILD_NUMBER="$BUILD_NUMBER"
if [[ -n "$REQUESTED_VERSION" ]]; then
    [[ "$REQUESTED_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
        || die "invalid requested version: $REQUESTED_VERSION"
fi
if [[ -n "$REQUESTED_BUILD_NUMBER" ]]; then
    [[ "$REQUESTED_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
        || die "requested build number must be a positive integer: $REQUESTED_BUILD_NUMBER"
fi
[[ "$SKIP_RELEASE_VERSION_BUMP" =~ ^[01]$ ]] \
    || die "SKIP_RELEASE_VERSION_BUMP must be 0 or 1"
[[ "$MINIMUM_SYSTEM_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || die "invalid minimum system version: $MINIMUM_SYSTEM_VERSION"
[[ "$RELEASE_CHANNEL" =~ ^[0-9A-Za-z._-]+$ ]] || die "invalid release channel: $RELEASE_CHANNEL"

read -r -a REQUESTED_ARCHITECTURES <<< "$BUILD_ARCHITECTURES"
[[ ${#REQUESTED_ARCHITECTURES[@]} -gt 0 ]] || die "no architectures requested"
for architecture in "${REQUESTED_ARCHITECTURES[@]}"; do
    case "$architecture" in arm64|x86_64) ;; *) die "unsupported architecture: $architecture" ;; esac
done

if [[ "$UNSIGNED" -eq 0 ]]; then
    [[ -n "$TEAM_ID" ]] || die "GLOBAL_TEAM_ID is required for a signed package"
    APPLICATION_IDENTITY="$(resolve_identity Application "$APPLICATION_IDENTITY" codesigning)"
    INSTALLER_IDENTITY="$(resolve_identity Installer "$INSTALLER_IDENTITY" basic)"
fi

PROJECT_VERSION=""
PROJECT_BUILD_NUMBER=""
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    if [[ "$SKIP_RELEASE_VERSION_BUMP" -eq 0 ]]; then
        "$ROOT_DIR/scripts/bump-release-version.sh" --project "$PROJECT_PATH"
    else
        echo "Release version bump skipped."
    fi

    PROJECT_VERSION="$(read_build_setting MARKETING_VERSION)"
    PROJECT_BUILD_NUMBER="$(read_build_setting CURRENT_PROJECT_VERSION)"
    [[ "$PROJECT_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
        || die "invalid Xcode project version: $PROJECT_VERSION"
    [[ "$PROJECT_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
        || die "invalid Xcode project build number: $PROJECT_BUILD_NUMBER"
fi

[[ "$BUILD_ROOT" == "$ROOT_DIR/Build/Package" ]] || die "unexpected build root: $BUILD_ROOT"
if [[ "$SKIP_BUILD" -eq 0 ]]; then
    rm -rf "$BUILD_ROOT"
else
    [[ -n "$BINARY_PATH" ]] \
        || BINARY_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$EXECUTABLE_NAME"
    rm -rf "$INTERMEDIATE_DIR" "$OUTPUT_DIR"
fi
mkdir -p "$DERIVED_DATA_DIR" "$INTERMEDIATE_DIR" "$PAYLOAD_ROOT" "$OUTPUT_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "Building $SCHEME $PROJECT_VERSION ($PROJECT_BUILD_NUMBER) for $BUILD_ARCHITECTURES..."
    xcodebuild -quiet -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
        -destination "generic/platform=macOS" -derivedDataPath "$DERIVED_DATA_DIR" \
        SYMROOT="$DERIVED_DATA_DIR/Build/Products" \
        OBJROOT="$DERIVED_DATA_DIR/Build/Intermediates.noindex" \
        ARCHS="$BUILD_ARCHITECTURES" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
        ENABLE_CODE_COVERAGE=NO \
        MARKETING_VERSION="$PROJECT_VERSION" CURRENT_PROJECT_VERSION="$PROJECT_BUILD_NUMBER" build
    BINARY_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$EXECUTABLE_NAME"
fi
[[ -f "$BINARY_PATH" ]] || die "Launch Agent binary not found: $BINARY_PATH"

STAGED_BINARY="$INTERMEDIATE_DIR/$EXECUTABLE_NAME"
install -m 0755 "$BINARY_PATH" "$STAGED_BINARY"
EMBEDDED_INFO_PLIST="$INTERMEDIATE_DIR/Embedded-Info.plist"
otool -v -s __TEXT __info_plist "$STAGED_BINARY" \
    | awk 'BEGIN { copying = 0 } /^<\?xml/ { copying = 1 } copying { print }' > "$EMBEDDED_INFO_PLIST"
plutil -lint "$EMBEDDED_INFO_PLIST" >/dev/null

embedded_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$EMBEDDED_INFO_PLIST")"
embedded_display_name="$(plutil -extract CFBundleDisplayName raw -o - "$EMBEDDED_INFO_PLIST")"
embedded_version="$(plutil -extract CFBundleShortVersionString raw -o - "$EMBEDDED_INFO_PLIST")"
embedded_build="$(plutil -extract CFBundleVersion raw -o - "$EMBEDDED_INFO_PLIST")"
[[ "$embedded_identifier" == "$COMPONENT_IDENTIFIER" ]] || die "unexpected embedded identifier: $embedded_identifier"
[[ "$embedded_display_name" == "$DISPLAY_NAME" ]] || die "unexpected embedded display name: $embedded_display_name"
[[ "$embedded_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] \
    || die "invalid embedded version: $embedded_version"
[[ "$embedded_build" =~ ^[1-9][0-9]*$ ]] || die "invalid embedded build number: $embedded_build"
if [[ -n "$PROJECT_VERSION" && "$embedded_version" != "$PROJECT_VERSION" ]]; then
    die "embedded version $embedded_version does not match Xcode project version $PROJECT_VERSION"
fi
if [[ -n "$PROJECT_BUILD_NUMBER" && "$embedded_build" != "$PROJECT_BUILD_NUMBER" ]]; then
    die "embedded build $embedded_build does not match Xcode project build $PROJECT_BUILD_NUMBER"
fi
if [[ -n "$REQUESTED_VERSION" && "$embedded_version" != "$REQUESTED_VERSION" ]]; then
    die "requested package version $REQUESTED_VERSION does not match embedded version $embedded_version"
fi
if [[ -n "$REQUESTED_BUILD_NUMBER" && "$embedded_build" != "$REQUESTED_BUILD_NUMBER" ]]; then
    die "requested package build $REQUESTED_BUILD_NUMBER does not match embedded build $embedded_build"
fi
VERSION="$embedded_version"
BUILD_NUMBER="$embedded_build"

built_architectures="$(lipo -archs "$STAGED_BINARY")"
for architecture in "${REQUESTED_ARCHITECTURES[@]}"; do
    [[ " $built_architectures " == *" $architecture "* ]] || die "binary is missing requested architecture: $architecture"
done

if [[ "$UNSIGNED" -eq 0 ]]; then
    echo "Signing Launch Agent with: $APPLICATION_IDENTITY"
    codesign --force --timestamp --options runtime --identifier "$COMPONENT_IDENTIFIER" \
        --entitlements "$ENTITLEMENTS_PATH" \
        --sign "$APPLICATION_IDENTITY" "$STAGED_BINARY"
    codesign --verify --strict --verbose=2 "$STAGED_BINARY"
    signed_team="$(codesign -d --verbose=4 "$STAGED_BINARY" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$signed_team" == "$TEAM_ID" ]] || die "unexpected signing team: $signed_team"
    SIGNED_ENTITLEMENTS="$INTERMEDIATE_DIR/Signed-Entitlements.plist"
    codesign -d --entitlements "$SIGNED_ENTITLEMENTS" --xml "$STAGED_BINARY"
    signed_app_group="$(plutil -extract 'com\.apple\.security\.application-groups.0' raw -o - "$SIGNED_ENTITLEMENTS")"
    [[ "$signed_app_group" == "group.org.eof.apps" ]] \
        || die "signed Launch Agent is missing the expected application group"
fi

PAYLOAD_BINARY="$PAYLOAD_ROOT${INSTALL_BINARY_PATH}"
PAYLOAD_PLIST="$PAYLOAD_ROOT${INSTALL_PLIST_PATH}"
mkdir -p "$(dirname "$PAYLOAD_BINARY")" "$(dirname "$PAYLOAD_PLIST")"
install -m 0755 "$STAGED_BINARY" "$PAYLOAD_BINARY"
sed "s|__AGENT_PATH__|$INSTALL_BINARY_PATH|g" "$PLIST_TEMPLATE" > "$PAYLOAD_PLIST"
chmod 0644 "$PAYLOAD_PLIST"
plutil -lint "$PAYLOAD_PLIST" >/dev/null
payload_label="$(plutil -extract Label raw -o - "$PAYLOAD_PLIST")"
payload_program="$(plutil -extract ProgramArguments.0 raw -o - "$PAYLOAD_PLIST")"
[[ "$payload_label" == "$LAUNCHD_LABEL" ]] || die "LaunchAgent label mismatch: $payload_label"
[[ "$payload_program" == "$INSTALL_BINARY_PATH" ]] || die "LaunchAgent program path mismatch"
plutil -extract MachServices xml1 -o - "$PAYLOAD_PLIST" \
    | grep -F "<key>$MACH_SERVICE</key>" >/dev/null || die "Mach service missing from LaunchAgent plist"
if grep -F '__AGENT_PATH__' "$PAYLOAD_PLIST" >/dev/null; then
    die "unresolved Agent path placeholder in LaunchAgent plist"
fi

pkgbuild --root "$PAYLOAD_ROOT" --scripts "$PACKAGING_DIR/Scripts" \
    --identifier "$PACKAGE_IDENTIFIER" --version "$VERSION" --install-location / \
    --ownership recommended \
    --min-os-version "$MINIMUM_SYSTEM_VERSION" "$COMPONENT_PACKAGE"

RENDERED_DISTRIBUTION="$INTERMEDIATE_DIR/Distribution.xml"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__MINIMUM_SYSTEM_VERSION__/$MINIMUM_SYSTEM_VERSION/g" \
    "$PACKAGING_DIR/Distribution.xml" > "$RENDERED_DISTRIBUTION"
xmllint --noout "$RENDERED_DISTRIBUTION"

FINAL_PACKAGE="$OUTPUT_DIR/MCPStudioLaunchAgent-$VERSION.pkg"
productbuild_arguments=(--distribution "$RENDERED_DISTRIBUTION" --package-path "$INTERMEDIATE_DIR" --resources "$PACKAGING_DIR")
if [[ "$UNSIGNED" -eq 0 ]]; then productbuild_arguments+=(--sign "$INSTALLER_IDENTITY"); fi
productbuild "${productbuild_arguments[@]}" "$FINAL_PACKAGE"

EXPANDED_PACKAGE="$INTERMEDIATE_DIR/ExpandedPackage"
pkgutil --expand-full "$FINAL_PACKAGE" "$EXPANDED_PACKAGE"
[[ -f "$EXPANDED_PACKAGE/MCPStudioLaunchAgent-component.pkg/Payload${INSTALL_BINARY_PATH}" ]] \
    || die "packaged Launch Agent binary is missing"
[[ -f "$EXPANDED_PACKAGE/MCPStudioLaunchAgent-component.pkg/Payload${INSTALL_PLIST_PATH}" ]] \
    || die "packaged LaunchAgent plist is missing"

NOTARIZED=false
if [[ "$UNSIGNED" -eq 0 ]]; then
    signature_report="$(pkgutil --check-signature "$FINAL_PACKAGE")"
    printf '%s\n' "$signature_report"
    grep -F "($TEAM_ID)" <<< "$signature_report" >/dev/null \
        || die "installer package is not signed by expected team: $TEAM_ID"
    if [[ "$SKIP_NOTARIZATION" -eq 0 ]]; then
        echo "Notarizing installer package..."
        notarize_package "$FINAL_PACKAGE"
        spctl --assess --type install --verbose=2 "$FINAL_PACKAGE"
        NOTARIZED=true
    fi
fi

PACKAGE_SHA256="$(shasum -a 256 "$FINAL_PACKAGE" | awk '{print $1}')"
PACKAGE_SIZE="$(stat -f %z "$FINAL_PACKAGE")"
SHA256_FILE="$OUTPUT_DIR/MCPStudioLaunchAgent-$VERSION.pkg.sha256"
METADATA_FILE="$OUTPUT_DIR/MCPStudioLaunchAgent-$VERSION.release.json"
METADATA_PLIST="$INTERMEDIATE_DIR/MCPStudioLaunchAgent-$VERSION.release.plist"
printf '%s  %s\n' "$PACKAGE_SHA256" "$(basename "$FINAL_PACKAGE")" > "$SHA256_FILE"

plutil -create xml1 "$METADATA_PLIST"
plutil -insert schemaVersion -integer 1 "$METADATA_PLIST"
plutil -insert product -string "MCPStudioLaunchAgent" "$METADATA_PLIST"
plutil -insert displayName -string "$DISPLAY_NAME" "$METADATA_PLIST"
plutil -insert version -string "$VERSION" "$METADATA_PLIST"
plutil -insert build -string "$BUILD_NUMBER" "$METADATA_PLIST"
plutil -insert channel -string "$RELEASE_CHANNEL" "$METADATA_PLIST"
plutil -insert file -string "$(basename "$FINAL_PACKAGE")" "$METADATA_PLIST"
plutil -insert size -integer "$PACKAGE_SIZE" "$METADATA_PLIST"
plutil -insert sha256 -string "$PACKAGE_SHA256" "$METADATA_PLIST"
plutil -insert minimumSystemVersion -string "$MINIMUM_SYSTEM_VERSION" "$METADATA_PLIST"
plutil -insert componentIdentifier -string "$COMPONENT_IDENTIFIER" "$METADATA_PLIST"
plutil -insert packageIdentifier -string "$PACKAGE_IDENTIFIER" "$METADATA_PLIST"
plutil -insert launchdLabel -string "$LAUNCHD_LABEL" "$METADATA_PLIST"
plutil -insert machService -string "$MACH_SERVICE" "$METADATA_PLIST"
plutil -insert binaryInstallPath -string "$INSTALL_BINARY_PATH" "$METADATA_PLIST"
plutil -insert launchAgentPlistPath -string "$INSTALL_PLIST_PATH" "$METADATA_PLIST"
plutil -insert architectures -array "$METADATA_PLIST"
architecture_index=0
for architecture in "${REQUESTED_ARCHITECTURES[@]}"; do
    plutil -insert "architectures.$architecture_index" -string "$architecture" "$METADATA_PLIST"
    architecture_index=$((architecture_index + 1))
done
if [[ "$UNSIGNED" -eq 0 ]]; then
    plutil -insert signed -bool true "$METADATA_PLIST"
else
    plutil -insert signed -bool false "$METADATA_PLIST"
fi
plutil -insert notarized -bool "$NOTARIZED" "$METADATA_PLIST"
plutil -insert generatedAt -string "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$METADATA_PLIST"
plutil -lint "$METADATA_PLIST" >/dev/null
plutil -convert json -r -o "$METADATA_FILE" "$METADATA_PLIST"

LOCAL_RELEASE_PACKAGE=""
if [[ "$SKIP_LOCAL_RELEASE" -eq 0 && ( "$NOTARIZED" == true || "$RELEASE_DIR_EXPLICIT" -eq 1 ) ]]; then
    if [[ "$RELEASE_DIR" == "$DEFAULT_RELEASE_DIR" ]]; then
        [[ -d "$RELEASE_DIR" ]] || die "Launch Agent release directory not found: $RELEASE_DIR"
        [[ -f "$(dirname "$RELEASE_DIR")/release-notes.html" ]] \
            || die "Launch Agent release layout is incomplete: missing release-notes.html"
    else
        mkdir -p "$RELEASE_DIR"
    fi
    copy_release_package "$FINAL_PACKAGE"
    LOCAL_RELEASE_PACKAGE="$RELEASE_DIR/$(basename "$FINAL_PACKAGE")"
    echo "Placed final package in local release mirror: $LOCAL_RELEASE_PACKAGE"
elif [[ "$SKIP_LOCAL_RELEASE" -eq 0 ]]; then
    echo "Local release mirror unchanged: only notarized packages are staged automatically."
fi

echo
echo "Launch Agent package prepared successfully."
echo "  Package:   $FINAL_PACKAGE"
echo "  SHA-256:   $SHA256_FILE"
echo "  Metadata:  $METADATA_FILE"
echo "  Signed:    $([[ "$UNSIGNED" -eq 0 ]] && echo yes || echo no)"
echo "  Notarized: $NOTARIZED"
if [[ -n "$LOCAL_RELEASE_PACKAGE" ]]; then
    echo "  Release:   $LOCAL_RELEASE_PACKAGE"
fi
