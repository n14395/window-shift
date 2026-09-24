#!/bin/bash
# WindowShift — build, package, sign and publish.
#
#   ./build.sh                 build the production build/WindowShift.app
#   ./build.sh --dmg           …and package it into build/WindowShift.dmg
#   ./build.sh --sign          …Developer ID sign the .app and .dmg, notarize and staple
#   ./build.sh --version N.N   set the app's version to N.N (committed) before building
#   ./build.sh --publish vN.N  tag, push and cut a GitHub release from build/WindowShift.dmg
#   ./build.sh --sparkle       …with the Sparkle updater built in (combine with any of the above)
#
# Flags combine — `./build.sh --sign --publish v1.2` sets the version to 1.2, commits
# that, builds, signs, notarizes and releases in one go. `--publish` on its own does
# not rebuild: it requires build/WindowShift.dmg to already exist, and given no version it
# releases the version the app inside that .dmg reports. The version lives in the
# project (set_version knows where for this repo); --version and a building --publish
# write it there and commit just that, so the tag, the appcast and the next App Store
# archive all say the same number. After the release exists --publish also regenerates
# this app's Cask in the Homebrew tap (HOMEBREW_TAP_DIR, default ~/build/homebrew-tap),
# commits and pushes it, so `brew upgrade` picks the version up.
#
# The default build is the App Store build and never contains Sparkle. `--sparkle`
# is for direct-download releases: it embeds the updater, adds "Check for Updates…"
# under "About" in the application menu, checks for updates on launch, and with
# `--publish` also uploads the appcast.xml that shipped copies poll. Never submit
# a --sparkle build to the App Store.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="WindowShift"
BUILD_DIR="$PWD/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
BUNDLE_ID="dev.nwf.WindowShift"
ENTITLEMENTS=""
# Where --sparkle builds look for updates. `--sparkle --publish` attaches appcast.xml
# to every GitHub release, and this URL always resolves to the newest release's copy.
SPARKLE_FEED_URL="https://github.com/n14395/window-shift/releases/latest/download/appcast.xml"

# Exported from ~/.zshrc. The literal fallback keeps the script working when it is
# run from a shell that never sourced it (cron, a GUI runner, `env -i`).
DEV_TEAM_IDENTITY="${DEV_TEAM_IDENTITY:-Developer ID Application: Nicholas Fay (P52946XHRJ)}"
NOTARY_PROFILE="notary-profile"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

WANT_DMG=0
WANT_SIGN=0
WANT_SPARKLE=0
WANT_PUBLISH=0
PUBLISH_VERSION=""
BUILD_VERSION=""
VERSION_NUM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)     WANT_DMG=1 ;;
        --sign)    WANT_SIGN=1 ;;
        --sparkle) WANT_SPARKLE=1 ;;
        --version)
            [[ $# -ge 2 ]] || die "--version needs a version argument, e.g. --version 1.2"
            BUILD_VERSION="$2"; shift ;;
        --version=*) BUILD_VERSION="${1#*=}" ;;
        --publish)
            WANT_PUBLISH=1
            # The version is optional: bare --publish releases what the app reports.
            if [[ $# -ge 2 && "$2" != -* ]]; then PUBLISH_VERSION="$2"; shift; fi ;;
        --publish=*) WANT_PUBLISH=1; PUBLISH_VERSION="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown flag: $1 (try --help)" ;;
    esac
    shift
done

# vN.N or vN.N.N — anything else is a typo we would rather catch before tagging.
# --version takes the same shape, with or without the v.
if [[ -n "$PUBLISH_VERSION" ]]; then
    [[ "$PUBLISH_VERSION" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
        || die "--publish needs a version like v1.2 or v1.2.3 (got: '$PUBLISH_VERSION')"
    VERSION_NUM="${PUBLISH_VERSION#v}"
fi
if [[ -n "$BUILD_VERSION" ]]; then
    BUILD_VERSION="${BUILD_VERSION#v}"
    [[ "$BUILD_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
        || die "--version needs a version like 1.2 or 1.2.3 (got: '$BUILD_VERSION')"
fi

# A build happens unless --publish is the only thing asked for. A build that goes
# straight to --publish vN.N is the vN.N build, so it sets the version first.
BUILDING=1
if [[ $WANT_PUBLISH -eq 1 && $WANT_SIGN -eq 0 && $WANT_DMG -eq 0 ]]; then BUILDING=0; fi
if [[ $BUILDING -eq 0 && -n "$BUILD_VERSION" ]]; then
    die "--version sets the version for a build, and --publish alone does not build — add --sign or --dmg"
fi
if [[ -n "$BUILD_VERSION" && -n "$PUBLISH_VERSION" && "$BUILD_VERSION" != "$VERSION_NUM" ]]; then
    die "--version $BUILD_VERSION and --publish $PUBLISH_VERSION disagree"
fi
if [[ $BUILDING -eq 1 && -n "$PUBLISH_VERSION" ]]; then BUILD_VERSION="$VERSION_NUM"; fi

# Full Xcode, not the bare Command Line Tools: xcodebuild refuses to run under
# CLT, and even SwiftPM needs Xcode's toolchain for the SwiftUI macro plugins.
# Set DEVELOPER_DIR for this process only — the system default is left alone.
if [[ -z "${DEVELOPER_DIR:-}" ]] && ! xcode-select -p 2>/dev/null | grep -q '\.app'; then
    for xc in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [[ -d "$xc" ]]; then export DEVELOPER_DIR="$xc/Contents/Developer"; break; fi
    done
fi

# Sign the freshly-assembled bundle with a *stable* identity so macOS keeps its
# TCC grants (Accessibility, Screen Recording, Automation…) across rebuilds. An
# ad-hoc signature is keyed to the code hash, which changes on every build, so
# the system forgets the grant and re-prompts. --sign re-signs with Developer ID
# on top of this; this is the local default.
dev_sign() {
    local id args=()
    id="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development/ {print $2; exit}')}"
    [[ -n "$BUNDLE_ID" ]] && args+=(--identifier "$BUNDLE_ID")
    [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]] && args+=(--entitlements "$ENTITLEMENTS")
    if [[ -n "$id" ]]; then
        codesign --force --sign "$id" ${args[@]+"${args[@]}"} "$APP_PATH"
        echo "    signed with $id"
    else
        codesign --force --sign - ${args[@]+"${args[@]}"} "$APP_PATH"
        echo "    ad-hoc signed (no Apple Development identity found)"
    fi
}

# A plain drag-to-install image: the app plus an /Applications symlink, nothing
# else. Staged under build/ so the volume contains exactly those two items and
# no stray DerivedData.
DMG_STAGING="$BUILD_DIR/.dmg-staging"
cleanup() { rm -rf "$DMG_STAGING"; return 0; }
trap cleanup EXIT

make_dmg() {
    [[ -d "$APP_PATH" ]] || die "$APP_PATH not found — build it first"
    step "Packaging $APP_NAME.dmg"
    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    # ditto, not cp: it preserves the code signature and extended attributes.
    ditto "$APP_PATH" "$DMG_STAGING/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGING/Applications"
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" \
        -fs HFS+ -format UDZO -ov -quiet "$DMG_PATH"
    rm -rf "$DMG_STAGING"
    echo "    $DMG_PATH"
}

# codesign never recurses into nested code, and the notary service rejects a
# bundle whose frameworks / app extensions / bundled helper binaries still carry
# an older signature. So sign inside-out, deepest path first, then the bundle
# itself. Entitlements are read back off each item and re-applied: a bare
# --force re-sign silently drops them, which would break sandboxing and TCC.
sign_one() {
    local target="$1" ent="" args=()
    if [[ "$target" == "$APP_PATH" && -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
        args+=(--entitlements "$ENTITLEMENTS")
    else
        ent="$(mktemp "${TMPDIR:-/tmp}/entitlements.XXXXXX")"
        if codesign -d --entitlements - --xml "$target" 2>/dev/null | grep -q '<plist'; then
            codesign -d --entitlements - --xml "$target" 2>/dev/null >"$ent"
            # get-task-allow is the debugger entitlement Xcode injects into
            # development-signed builds. The notary service rejects any binary
            # that still requests it, so drop it before re-signing.
            /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' \
                "$ent" >/dev/null 2>&1 || true
            args+=(--entitlements "$ent")
        else
            rm -f "$ent"; ent=""
        fi
    fi
    codesign --force --options runtime --timestamp \
        ${args[@]+"${args[@]}"} --sign "$DEV_TEAM_IDENTITY" "$target"
    [[ -n "$ent" ]] && rm -f "$ent"
    echo "    signed ${target#$BUILD_DIR/}"
}

sign_bundle() {
    local inner
    while IFS= read -r inner; do
        sign_one "$inner"
    done < <(
        {
            find "$APP_PATH/Contents" \
                \( -name '*.framework' -o -name '*.appex' -o -name '*.xpc' \
                   -o -name '*.app' -o -name '*.bundle' -o -name '*.dylib' \
                   -o -name '*.so' \) 2>/dev/null
            # Loose Mach-O helpers: bundled CLIs in Resources, login items…
            find "$APP_PATH/Contents" -type f -perm -u+x 2>/dev/null \
                | while IFS= read -r f; do
                      file -b "$f" 2>/dev/null | grep -q 'Mach-O' && printf '%s\n' "$f"
                  done
        } | grep -v "/Contents/MacOS/[^/]*$" \
          | sort -u | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2-
    )
    sign_one "$APP_PATH"
}

sign_and_notarize() {
    step "Developer ID signing $APP_NAME.app"
    echo "    identity: $DEV_TEAM_IDENTITY"
    sign_bundle

    make_dmg

    step "Developer ID signing $APP_NAME.dmg"
    codesign --force --timestamp --sign "$DEV_TEAM_IDENTITY" "$DMG_PATH"

    step "Verifying the .dmg signature"
    if ! codesign --verify --verbose=2 "$DMG_PATH"; then
        die "codesign --verify failed for $DMG_PATH — not submitting for notarization"
    fi

    step "Notarizing (this waits on Apple; usually a few minutes)"
    local out rc=0 status uuid
    out="$(xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || rc=$?
    printf '%s\n' "$out"
    [[ $rc -eq 0 ]] || die "notarytool submit failed (exit $rc)"

    status="$(printf '%s\n' "$out" | awk -F': *' '/^ *status:/ {print $2; exit}')"
    uuid="$(printf '%s\n' "$out"   | awk -F': *' '/^ *id:/     {print $2; exit}')"
    if [[ "$status" != "Accepted" ]]; then
        if [[ -n "$uuid" ]]; then
            step "Fetching the notarization log"
            xcrun notarytool log "$uuid" --keychain-profile "$NOTARY_PROFILE" \
                "$BUILD_DIR/notary-log.json" || true
            echo "    log written to $BUILD_DIR/notary-log.json"
        fi
        die "notarization returned status: ${status:-unknown}"
    fi

    step "Stapling the ticket"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"

    step "Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

    step "Notarized and stapled: $DMG_PATH"
}

publish() {
    step "Publishing $PUBLISH_VERSION"
    [[ -f "$DMG_PATH" ]] \
        || die ".dmg not found: $DMG_PATH — run ./build.sh --dmg (or --sign) first"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "$PWD is not inside a git repository — cannot tag or release"
    command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed"
    git remote get-url origin >/dev/null 2>&1 \
        || die "this repository has no 'origin' remote — cannot push the tag"

    local versioned="$BUILD_DIR/$APP_NAME-$VERSION_NUM.dmg"
    cp -f "$DMG_PATH" "$versioned"
    echo "    $versioned"

    # The branch first, so the tag never points at a commit GitHub has not seen
    # (the version bump is the usual one), and so a rejected push stops
    # everything before a tag exists.
    git push origin HEAD
    git tag -a "$PUBLISH_VERSION" -m "Release $PUBLISH_VERSION"
    git push origin "$PUBLISH_VERSION"
    gh release create "$PUBLISH_VERSION" "$versioned" --verify-tag --generate-notes
}

# After the GitHub release exists: regenerate this app's Cask in the Homebrew tap
# from the release just cut, commit it and push, so `brew upgrade` sees the new
# version. The tap's own bin/update-cask does the work — download, checksum,
# inspect the .app, write the Cask, commit, push — this only has to find it. The
# Cask token is the GitHub repository name; a first release needs the repo to
# have a GitHub description (gh repo edit -d '…'), which becomes the Cask's desc.
HOMEBREW_TAP_DIR="${HOMEBREW_TAP_DIR:-$HOME/build/homebrew-tap}"

# Runs before publish() so a missing or unpushable tap is caught before anything
# touches git. A missing .dmg is left for publish() to report.
check_homebrew_tap() {
    [[ -f "$DMG_PATH" ]] || return 0
    command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed"
    git remote get-url origin >/dev/null 2>&1 \
        || die "this repository has no 'origin' remote — cannot work out its GitHub name"
    [[ -x "$HOMEBREW_TAP_DIR/bin/update-cask" ]] \
        || die "Homebrew tap not found at $HOMEBREW_TAP_DIR — clone github.com/n14395/homebrew-tap there, or set HOMEBREW_TAP_DIR"
    # The tap itself must be the clone — not merely sit inside some enclosing
    # repository — or update-cask --push would commit into the wrong place.
    [[ "$(git -C "$HOMEBREW_TAP_DIR" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$HOMEBREW_TAP_DIR" && pwd -P)" ]] \
        && git -C "$HOMEBREW_TAP_DIR" remote get-url origin >/dev/null 2>&1 \
        || die "$HOMEBREW_TAP_DIR is not a git clone with an 'origin' remote — the Cask could not be pushed"
    local token; token="$(gh repo view --json name --jq .name)"
    [[ -f "$HOMEBREW_TAP_DIR/Casks/$token.rb" ]] \
        || [[ -n "$(gh repo view --json description --jq .description)" ]] \
        || die "first release of $token: give the GitHub repo a description (gh repo edit -d '…') — it becomes the Cask's desc"
}

publish_cask() {
    step "Updating the Homebrew tap"
    "$HOMEBREW_TAP_DIR/bin/update-cask" "$(gh repo view --json name --jq .name)" "$PUBLISH_VERSION" --push
}

# The version lives in the project — set_version() below knows where for this
# repo — and a release must agree with it. --version N.N, or a build that goes
# straight to --publish vN.N, writes N.N there and commits just that change, so
# the tag, the appcast and the next App Store archive all carry one number.
bump_version() {
    [[ -n "$BUILD_VERSION" ]] || return 0
    step "Setting the version to $BUILD_VERSION"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "$PWD is not inside a git repository — cannot commit the version bump"
    if [[ -n "$(git status --porcelain -- "${VERSION_FILES[@]}")" ]]; then
        die "uncommitted changes in: ${VERSION_FILES[*]} — commit or stash them first, so the version bump is a clean commit"
    fi
    set_version "$BUILD_VERSION"
    if [[ -z "$(git status --porcelain -- "${VERSION_FILES[@]}")" ]]; then
        echo "    already $BUILD_VERSION — nothing to commit"
        return 0
    fi
    git add -- "${VERSION_FILES[@]}"
    git commit -q -m "Bump version to $BUILD_VERSION" -- "${VERSION_FILES[@]}"
    echo "    committed \"Bump version to $BUILD_VERSION\": ${VERSION_FILES[*]}"
}

# After build_app: the bundle must report the version just set, or set_version()
# edited the wrong thing and the release would carry the old number.
check_version() {
    [[ -n "$BUILD_VERSION" ]] || return 0
    local built
    built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$built" == "$BUILD_VERSION" ]] \
        || die "the build reports version '${built:-?}' after set_version $BUILD_VERSION — set_version() is editing the wrong file"
}

# Look inside build/AppName.dmg — the artifact --publish releases, which need
# not match whatever build/AppName.app currently holds. Prints
# "sparkle=<0|1> version=<CFBundleShortVersionString>".
inspect_dmg() {
    local mnt="$BUILD_DIR/.dmg-mount" has=0 ver out
    mkdir -p "$mnt"
    out="$(hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$DMG_PATH" 2>&1)" \
        || die "could not mount $DMG_PATH: $out"
    [[ -d "$mnt/$APP_NAME.app/Contents/Frameworks/Sparkle.framework" ]] && has=1
    ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$mnt/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || true)"
    hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet || true
    rmdir "$mnt" 2>/dev/null || true
    echo "sparkle=$has version=$ver"
}

# Runs before publish() so a wrong artifact is caught before anything touches
# git. With no version on --publish, the version is the one the app reports;
# with one, they must agree — it is what the tag and the appcast will say. A
# Sparkle release must actually contain Sparkle, and a Sparkle build must not
# slip out without its appcast.
check_dmg() {
    [[ -f "$DMG_PATH" ]] || return 0
    local info has ver
    info="$(inspect_dmg)"
    has="${info#sparkle=}"; has="${has%% *}"
    ver="${info##*version=}"
    if [[ -z "$PUBLISH_VERSION" ]]; then
        [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
            || die "the app inside $DMG_PATH reports version '$ver', which cannot be a vN.N tag — pass one to --publish"
        PUBLISH_VERSION="v$ver"; VERSION_NUM="$ver"
    elif [[ "$ver" != "$VERSION_NUM" ]]; then
        die "the app inside $DMG_PATH is version $ver but you are publishing $PUBLISH_VERSION — build it again with --sign --publish $PUBLISH_VERSION, which sets the version first"
    fi
    if [[ $WANT_SPARKLE -eq 1 ]]; then
        [[ "$has" == "1" ]] \
            || die "$DMG_PATH was built without --sparkle — rebuild with ./build.sh --sparkle --sign (or --dmg) first"
    else
        [[ "$has" == "0" ]] \
            || die "$DMG_PATH contains Sparkle — publish it with --sparkle so the appcast is uploaded too"
    fi
}

# --sparkle: ship the Sparkle updater for direct-download releases. Sparkle must
# never reach the App Store build — Apple rejects apps that update themselves —
# so nothing here runs, links or gets copied unless the flag was given: every
# function below is a no-op without it and the splice arrays stay empty. The
# pinned release is downloaded into build/.sparkle and checksummed.
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_DIR="$BUILD_DIR/.sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"
SPARKLE_BIN="$SPARKLE_DIR/bin"

# build_app() splices one of these into its compile command: Xcode projects pass
# SPARKLE_XCB_SETTINGS to xcodebuild, SwiftPM packages pass SPARKLE_SWIFT_FLAGS
# to `swift build`, raw swiftc invocations take SPARKLE_SWIFTC_FLAGS. Each one
# defines SPARKLE for `#if SPARKLE`, links the framework, and adds the rpath
# that finds it in Contents/Frameworks at run time.
SPARKLE_XCB_SETTINGS=()
SPARKLE_SWIFT_FLAGS=()
SPARKLE_SWIFTC_FLAGS=()
if [[ $WANT_SPARKLE -eq 1 ]]; then
    SPARKLE_XCB_SETTINGS=(
        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) SPARKLE'
        "FRAMEWORK_SEARCH_PATHS=\$(inherited) $SPARKLE_DIR"
        'OTHER_LDFLAGS=$(inherited) -framework Sparkle'
        'LD_RUNPATH_SEARCH_PATHS=$(inherited) @executable_path/../Frameworks'
    )
    SPARKLE_SWIFT_FLAGS=(
        -Xswiftc -DSPARKLE -Xswiftc "-F$SPARKLE_DIR"
        -Xlinker "-F$SPARKLE_DIR" -Xlinker -framework -Xlinker Sparkle
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks
    )
    SPARKLE_SWIFTC_FLAGS=(
        -DSPARKLE "-F$SPARKLE_DIR" -framework Sparkle
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks
    )
fi

fetch_sparkle() {
    [[ $WANT_SPARKLE -eq 1 ]] || return 0
    if [[ -d "$SPARKLE_FRAMEWORK" && "$(cat "$SPARKLE_DIR/.version" 2>/dev/null)" == "$SPARKLE_VERSION" ]]; then
        return 0
    fi
    step "Fetching Sparkle $SPARKLE_VERSION"
    local url="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    local tarball="$BUILD_DIR/.sparkle-$SPARKLE_VERSION.tar.xz" sum
    curl -fsSL --retry 3 -o "$tarball" "$url" || die "could not download $url"
    sum="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    [[ "$sum" == "$SPARKLE_SHA256" ]] \
        || die "Sparkle $SPARKLE_VERSION checksum mismatch: got $sum, expected $SPARKLE_SHA256"
    rm -rf "$SPARKLE_DIR"
    mkdir -p "$SPARKLE_DIR"
    tar -xf "$tarball" -C "$SPARKLE_DIR"
    rm -f "$tarball"
    [[ -d "$SPARKLE_FRAMEWORK" && -x "$SPARKLE_BIN/generate_appcast" ]] \
        || die "unexpected layout inside Sparkle-$SPARKLE_VERSION.tar.xz: no Sparkle.framework or bin/"
    echo "$SPARKLE_VERSION" >"$SPARKLE_DIR/.version"
    echo "    $SPARKLE_DIR"
}

# The EdDSA public key shipped apps use to verify updates. It is read from the
# login keychain, where Sparkle's generate_keys keeps the private half, so it
# can never disagree with the key --publish signs with. One key serves every
# app: generate it once, then back it up with `generate_keys -x <file>`.
sparkle_public_key() {
    if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
        printf '%s\n' "$SPARKLE_PUBLIC_KEY"
        return 0
    fi
    "$SPARKLE_BIN/generate_keys" -p 2>/dev/null \
        || die "no Sparkle signing key in the keychain — run '$SPARKLE_BIN/generate_keys' once, or export SPARKLE_PUBLIC_KEY"
}

# PlistBuddy's Add fails on a key that exists and Set on one that does not.
plist_set() {
    local file="$1" key="$2" type="$3" value="$4"
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$file" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$file" >/dev/null
}

# Add Sparkle to the finished bundle: the framework, the SU* Info.plist keys,
# the entitlements a sandboxed app needs, and then a fresh signature. Copying
# the framework in breaks the bundle's seal, and the hardened runtime's library
# validation only loads frameworks signed by the app's own team — the tarball's
# framework is ad-hoc signed — so the framework is re-signed inside-out with
# the same identity as the app. Never --deep: it drops the XPC services' own
# entitlements. This is the dev-time signature; --sign re-signs everything.
embed_sparkle() {
    [[ $WANT_SPARKLE -eq 1 ]] || return 0
    [[ -n "$SPARKLE_FEED_URL" ]] || die "SPARKLE_FEED_URL is empty — set it at the top of build.sh"
    step "Embedding Sparkle $SPARKLE_VERSION"
    local pb=/usr/libexec/PlistBuddy
    local plist="$APP_PATH/Contents/Info.plist"
    local fw="$APP_PATH/Contents/Frameworks/Sparkle.framework"
    local ents="$SPARKLE_DIR/$APP_NAME.entitlements"
    local key bundle_id version base="" id flags runtime=() args=()

    key="$(sparkle_public_key)" || exit 1
    bundle_id="$($pb -c 'Print :CFBundleIdentifier' "$plist")"
    version="$($pb -c 'Print :CFBundleShortVersionString' "$plist")"

    rm -rf "$fw"
    mkdir -p "$APP_PATH/Contents/Frameworks"
    ditto "$SPARKLE_FRAMEWORK" "$fw"

    # Sparkle decides "newer" by CFBundleVersion, not the marketing version, and
    # these projects leave the build number at 1. The Sparkle build therefore
    # uses the marketing version as its build number — the same number
    # --publish tags and check_sparkle_dmg verifies.
    plist_set "$plist" CFBundleVersion string "$version"
    plist_set "$plist" SUFeedURL string "$SPARKLE_FEED_URL"
    plist_set "$plist" SUPublicEDKey string "$key"
    # Check on launch (and then daily) without first asking the user's permission.
    plist_set "$plist" SUEnableAutomaticChecks bool true

    # Entitlements: start from the file this script signs with, otherwise from
    # what the build already signed the app with. A sandboxed app additionally
    # needs the mach-lookup exceptions that reach Sparkle's installer, its
    # installer launcher XPC service, and outgoing network access for the feed.
    if [[ -n "$ENTITLEMENTS" && -f "$ENTITLEMENTS" ]]; then
        cp -f "$ENTITLEMENTS" "$ents"; base="$ents"
    elif codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | grep -q '<plist'; then
        codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null >"$ents"; base="$ents"
    fi
    if [[ -n "$base" ]]; then
        if [[ "$($pb -c 'Print :com.apple.security.app-sandbox' "$ents" 2>/dev/null)" == "true" ]]; then
            plist_set "$plist" SUEnableInstallerLauncherService bool true
            local mach=':com.apple.security.temporary-exception.mach-lookup.global-name'
            $pb -c "Add $mach array" "$ents" >/dev/null 2>&1 || true
            grep -q -- "$bundle_id-spks" "$ents" || $pb -c "Add $mach: string $bundle_id-spks" "$ents"
            grep -q -- "$bundle_id-spki" "$ents" || $pb -c "Add $mach: string $bundle_id-spki" "$ents"
            plist_set "$ents" com.apple.security.network.client bool true
        fi
        $pb -c 'Delete :com.apple.security.get-task-allow' "$ents" >/dev/null 2>&1 || true
        ENTITLEMENTS="$ents"
        args+=(--entitlements "$ENTITLEMENTS")
    fi
    [[ -n "$BUNDLE_ID" ]] && args+=(--identifier "$BUNDLE_ID")

    # The identity dev_sign uses: a stable Apple Development certificate keeps
    # TCC grants across rebuilds. Keep the hardened runtime if the build had it
    # (read into a variable first: under pipefail, `grep -q` closing the pipe
    # early makes codesign's unbuffered stderr fail the whole pipeline).
    id="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development/ {print $2; exit}')}"
    [[ -n "$id" ]] || id="-"
    flags="$(codesign -d --verbose "$APP_PATH" 2>&1 | grep 'flags=' || true)"
    if [[ "$id" != "-" && "$flags" == *runtime* ]]; then
        runtime=(--options runtime)
    fi
    local cs=(codesign --force --sign "$id" ${runtime[@]+"${runtime[@]}"})
    "${cs[@]}" "$fw/Versions/B/XPCServices/Installer.xpc"
    "${cs[@]}" --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
    "${cs[@]}" "$fw/Versions/B/Autoupdate"
    "${cs[@]}" "$fw/Versions/B/Updater.app"
    "${cs[@]}" "$fw"
    "${cs[@]}" ${args[@]+"${args[@]}"} "$APP_PATH"
    echo "    ${fw#$BUILD_DIR/}"
    echo "    feed: $SPARKLE_FEED_URL"
    if [[ "$id" == "-" ]]; then
        echo "    ad-hoc signed (no Apple Development identity found)"
    else
        echo "    signed with $id"
    fi
}

# After the GitHub release exists: sign the versioned .dmg with the EdDSA key,
# write a one-item appcast.xml for it and attach it to the release, where
# SPARKLE_FEED_URL (…/releases/latest/download/appcast.xml) resolves to it.
publish_appcast() {
    [[ $WANT_SPARKLE -eq 1 ]] || return 0
    step "Publishing the Sparkle appcast"
    local dir="$BUILD_DIR/.appcast" repo
    local versioned="$BUILD_DIR/$APP_NAME-$VERSION_NUM.dmg"
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -f "$versioned" "$dir/"
    "$SPARKLE_BIN/generate_appcast" \
        --download-url-prefix "https://github.com/$repo/releases/download/$PUBLISH_VERSION/" \
        --link "https://github.com/$repo/releases/tag/$PUBLISH_VERSION" \
        -o "$dir/appcast.xml" "$dir"
    gh release upload "$PUBLISH_VERSION" "$dir/appcast.xml" --clobber
    echo "    $SPARKLE_FEED_URL"
}

build_app() {
    step "Building $APP_NAME (release)"
    swift build -c release ${SPARKLE_SWIFT_FLAGS[@]+"${SPARKLE_SWIFT_FLAGS[@]}"}

    rm -rf "$APP_PATH"
    mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
    cp ".build/release/WindowShift" "$APP_PATH/Contents/MacOS/WindowShift"
    cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
    cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/AppIcon.icns"

    dev_sign
    echo "    $APP_PATH"
}

# Where this project keeps its version: the checked-in Info.plist the bundle is
# assembled from, mirrored into MARKETING_VERSION in the Xcode project kept for
# the IDE. perl rather than PlistBuddy, which rewrites the whole file in its own
# formatting and turns a one-line bump into a noisy diff.
VERSION_FILES=(Resources/Info.plist WindowShift.xcodeproj/project.pbxproj)
set_version() {
    perl -0pi -e "s/(<key>CFBundleShortVersionString<\/key>\s*<string>)[^<]*/\${1}$1/" Resources/Info.plist
    sed -i '' -E "s/(MARKETING_VERSION = )[0-9.]+;/\1$1;/" WindowShift.xcodeproj/project.pbxproj
}

mkdir -p "$BUILD_DIR"
bump_version
fetch_sparkle

# One production build: the bespoke build_app, then what every variant shares.
build() {
    build_app
    check_version
    embed_sparkle
}

if [[ $WANT_SIGN -eq 1 ]]; then
    build
    sign_and_notarize
elif [[ $WANT_DMG -eq 1 ]]; then
    build
    make_dmg
elif [[ $WANT_PUBLISH -eq 0 ]]; then
    build
fi

if [[ $WANT_PUBLISH -eq 1 ]]; then
    check_dmg
    check_homebrew_tap
    publish
    publish_appcast
    publish_cask
fi

exit 0
