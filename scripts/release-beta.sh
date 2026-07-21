#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IOS_PROJECT="$ROOT_DIR/iosApp/iosApp.xcodeproj"
TVOS_SCHEME="NuvioTV"
DERIVED_DATA="$ROOT_DIR/iosApp/build/tvos-ipa"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Release-appletvos"
APP_NAME="NuvioTV.app"
IPA_NAME="NuvioTV.ipa"
GH_REPO="youngchris29-art/NuvioMobile"
MIRROR_REPO="youngchris29-art/NuvioTV"   # public-facing fork repo; its releases/latest is the published download link
MIRROR_DIR="$(cd "$ROOT_DIR/.." && pwd)"
VERSION_XCCONFIG="$ROOT_DIR/iosApp/Configuration/Version.xcconfig"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-beta.sh [options]

Builds an unsigned tvOS IPA of NuvioTV and publishes it as a GitHub
prerelease tagged tvos-v<version>-beta.<n> (n auto-increments) on BOTH
youngchris29-art/NuvioMobile and youngchris29-art/NuvioTV (the public
download link points at NuvioTV's releases/latest).

Options:
  --tag <tag>       Use an explicit release tag instead of auto-incrementing
  --skip-build      Reuse the existing build products (repackage + publish only)
  --dry-run         Build and package, print what would be published, skip publish
  -h, --help        Show this help
EOF
}

TAG=""
SKIP_BUILD=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

cd "$ROOT_DIR"

MARKETING_VERSION="$(sed -n 's/^MARKETING_VERSION=//p' "$VERSION_XCCONFIG" | tr -d '[:space:]')"
BUILD_NUMBER="$(sed -n 's/^CURRENT_PROJECT_VERSION=//p' "$VERSION_XCCONFIG" | tr -d '[:space:]')"
[[ -n "$MARKETING_VERSION" ]] || { echo "error: MARKETING_VERSION not found in $VERSION_XCCONFIG" >&2; exit 1; }

HEAD_SHA="$(git rev-parse HEAD)"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "warning: working tree has uncommitted changes; the release tag will point at $HEAD_SHA which may not match what you build." >&2
fi

if ! git branch -r --contains "$HEAD_SHA" | grep -q 'origin/'; then
  echo "error: HEAD ($HEAD_SHA) is not pushed to origin — push first so the release tag has a valid target." >&2
  exit 1
fi

# The mirror release targets the outer NuvioTV checkout's HEAD; verify it is
# actually that repo (someone may have cloned NuvioMobile standalone).
MIRROR_SHA=""
if git -C "$MIRROR_DIR" remote get-url origin 2>/dev/null | grep -q "NuvioTV"; then
  MIRROR_SHA="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  if ! git -C "$MIRROR_DIR" branch -r --contains "$MIRROR_SHA" | grep -q 'origin/'; then
    echo "error: NuvioTV repo HEAD ($MIRROR_SHA) is not pushed to origin — push it first (the public download link lives on that repo)." >&2
    exit 1
  fi
else
  echo "warning: no NuvioTV checkout at $MIRROR_DIR — publishing to $GH_REPO only. The public releases/latest link on $MIRROR_REPO will go stale!" >&2
fi

latest_beta_n() { # latest_beta_n <repo> <prefix>
  gh release list --repo "$1" --limit 100 --json tagName -q '.[].tagName' \
    | { grep -F "$2" || true; } \
    | sed "s|^$2||" | sort -n | tail -1
}

if [[ -z "$TAG" ]]; then
  PREFIX="tvos-v${MARKETING_VERSION}-beta."
  LAST_N="$(latest_beta_n "$GH_REPO" "$PREFIX")"
  if [[ -n "$MIRROR_SHA" ]]; then
    MIRROR_LAST_N="$(latest_beta_n "$MIRROR_REPO" "$PREFIX")"
    [[ "${MIRROR_LAST_N:-0}" -gt "${LAST_N:-0}" ]] && LAST_N="$MIRROR_LAST_N"
  fi
  NEXT_N=$(( ${LAST_N:-0} + 1 ))
  TAG="${PREFIX}${NEXT_N}"
fi

echo "==> Release tag: $TAG (version $MARKETING_VERSION build $BUILD_NUMBER, commit ${HEAD_SHA:0:8} on $BRANCH)"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> Building $TVOS_SCHEME (Release, unsigned, tvOS device)"
  xcodebuild -project "$IOS_PROJECT" -scheme "$TVOS_SCHEME" -configuration Release \
    -destination "generic/platform=tvOS" -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    | tail -5
else
  echo "==> Skipping build, reusing $PRODUCTS_DIR"
fi

[[ -d "$PRODUCTS_DIR/$APP_NAME" ]] || { echo "error: $PRODUCTS_DIR/$APP_NAME not found" >&2; exit 1; }

echo "==> Packaging $IPA_NAME"
cd "$PRODUCTS_DIR"
rm -rf Payload "$IPA_NAME"
mkdir Payload
cp -R "$APP_NAME" Payload/
zip -qry "$IPA_NAME" Payload
rm -rf Payload
echo "    $(du -h "$IPA_NAME" | cut -f1 | tr -d ' ') $PRODUCTS_DIR/$IPA_NAME"

NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<EOF
# NuvioTV for Apple TV — Beta (v${MARKETING_VERSION})

Unsigned tvOS IPA for beta testing. This is a **fresh build** — no account, no addons. Sign in with your own Nuvio account and install your own addons after installing.

## How to install (no paid Apple Developer account needed)

You sideload this yourself with a **free Apple ID**. The signature is created on your machine at install time.

### Option A — Sideloadly (Mac/Windows)
1. Download \`NuvioTV.ipa\` from the assets below.
2. Install [Sideloadly](https://sideloadly.io/).
3. Make sure your computer and Apple TV are on the same network. Pair the Apple TV if prompted (on the Apple TV: Settings → Remotes and Devices → Remote App and Devices shows the pairing code).
4. Select your Apple TV as the target device in Sideloadly, drag \`NuvioTV.ipa\` in, enter your Apple ID, and hit **Start**.
5. If you get an "App ID limit" error, open Sideloadly's **Advanced** options and enable **Remove app extensions** (you only lose the home-screen Top Shelf row).

### Option B — atvloadly (self-hosted / Docker)
See [atvloadly](https://github.com/bitxeno/atvloadly) — a web UI for sideloading to Apple TV over the network, with automatic re-signing.

### First launch
Trust the developer certificate on the Apple TV when prompted (Settings → General → Privacy & Security).

## Free Apple ID limits (normal, not bugs)
- The app signature expires after **7 days** — just re-sideload (Sideloadly's background daemon or atvloadly can auto-refresh).
- Max **3 sideloaded apps** per free Apple ID at once.

## Build info
- Version ${MARKETING_VERSION} (build ${BUILD_NUMBER}), built from \`${HEAD_SHA:0:8}\` on \`${BRANCH}\`
- Includes MPV-based player (MPVKit) and Top Shelf extension
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> Dry run: would publish $TAG to $GH_REPO targeting $HEAD_SHA with asset $PRODUCTS_DIR/$IPA_NAME"
  [[ -n "$MIRROR_SHA" ]] && echo "==> Dry run: would publish $TAG to $MIRROR_REPO targeting $MIRROR_SHA"
  exit 0
fi

publish_release() { # publish_release <repo> <target_sha>
  echo "==> Publishing prerelease $TAG to $1"
  gh release create "$TAG" \
    --repo "$1" \
    --target "$2" \
    --title "NuvioTV (Apple TV) v${MARKETING_VERSION} ${TAG##*-}" \
    --notes-file "$NOTES_FILE" \
    --prerelease \
    "$PRODUCTS_DIR/$IPA_NAME#NuvioTV.ipa (unsigned tvOS IPA)"
}

publish_release "$GH_REPO" "$HEAD_SHA"
if [[ -n "$MIRROR_SHA" ]]; then
  publish_release "$MIRROR_REPO" "$MIRROR_SHA"
fi
