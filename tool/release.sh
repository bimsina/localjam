#!/usr/bin/env bash
# Builds a release on this machine and attaches it to a GitHub release. It
# stands in for .github/workflows/release.yml while GitHub Actions is off
# for this repository, and produces the same file names.
#
#   tool/release.sh              build, tag vX.Y.Z, create a DRAFT release
#   tool/release.sh --publish    the same, published straight away
#   tool/release.sh --dry-run    build and verify only: no tag, no release
#   tool/release.sh --no-macos   leave the macOS build out
#
# X.Y.Z is `version:` in apps/localjam_app/pubspec.yaml. Bump it (and the
# +build number, which Play requires to rise) and commit before running.
#
# Needs: macOS, Flutter, the Android SDK, `gh` signed in, and the upload
# keystore wired up in apps/localjam_app/android/key.properties
# (docs/release/ANDROID_RELEASE.md). The APK is checked against the upload
# certificate below before anything is tagged, so a debug-signed or
# wrongly-signed build never reaches a release.
#
# Linux and Windows are not built here: they need their own machines.
#
# Output lands in build/release/ (ignored by git). The .aab there is for the
# Play Console and is not attached to the GitHub release.
set -euo pipefail

# SHA-256 of the upload certificate (docs/release/ANDROID_RELEASE.md).
upload_cert_sha256="0de06ed297e2845d9e62007ef4d45c5c41557a533a8fdc8413b33995ba86715e"
package_id="dev.bimsina.localjam"
flutter_version="3.50.0"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/apps/localjam_app"
dist="$root/build/release"

dry_run=0
publish=0
macos=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --publish) publish=1 ;;
    --no-macos) macos=0 ;;
    -h | --help)
      sed -n '2,23p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
      exit 0
      ;;
    *)
      echo "release: unknown option $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

die() {
  echo "release: $*" >&2
  exit 1
}
step() { printf '\n==> %s\n' "$*"; }

cd "$root"

# --- preflight ---------------------------------------------------------------

for tool in git flutter gh shasum ditto; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done

name="$(sed -n -E 's/^version:[[:space:]]*([^+[:space:]]+).*/\1/p' "$app/pubspec.yaml")"
build="$(sed -n -E 's/^version:[[:space:]]*[^+[:space:]]+\+([0-9]+).*/\1/p' "$app/pubspec.yaml")"
[[ -n "$name" && -n "$build" ]] || die "no version X.Y.Z+N in apps/localjam_app/pubspec.yaml"
tag="v$name"

[[ -f "$app/android/key.properties" ]] ||
  die "apps/localjam_app/android/key.properties is missing: the release must be signed"

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
apksigner="$(find "$sdk/build-tools" -maxdepth 2 -name apksigner 2>/dev/null | sort | tail -n 1)"
[[ -x "$apksigner" ]] || die "no apksigner under $sdk/build-tools"

have="$(flutter --version 2>/dev/null | sed -n -E '1s/^Flutter ([^ ]+).*/\1/p')"
[[ "$have" == "$flutter_version" ]] ||
  echo "release: warning: Flutter $have, the project is pinned to $flutter_version" >&2

if [[ $dry_run -eq 0 ]]; then
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "not on main"
  [[ -z "$(git status --porcelain)" ]] || die "the working tree is not clean"
  git fetch --quiet origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] ||
    die "main and origin/main differ: push (or pull) first"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"
  if gh release view "$tag" >/dev/null 2>&1; then
    die "a release for $tag already exists: bump the version in pubspec.yaml"
  fi
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null &&
    [[ "$(git rev-parse "$tag^{commit}")" != "$(git rev-parse HEAD)" ]]; then
    die "tag $tag exists and is not this commit"
  fi
fi

echo "LocalJam $name (build $build) at $(git rev-parse --short HEAD)"

# --- build -------------------------------------------------------------------

step "web player"
tool/build_web_guest.sh
tool/build_web_guest.sh --check

step "android"
(
  cd "$app"
  flutter pub get
  # Never fall back to the debug key here, whatever the caller's shell has set.
  env -u LOCALJAM_ALLOW_DEBUG_SIGNING flutter build apk --release
  env -u LOCALJAM_ALLOW_DEBUG_SIGNING flutter build appbundle --release
)

rm -rf "$dist"
mkdir -p "$dist/upload" "$dist/play"
apk="$dist/upload/LocalJam-$name-android.apk"
cp "$app/build/app/outputs/flutter-apk/app-release.apk" "$apk"
cp "$app/build/app/outputs/bundle/release/app-release.aab" \
  "$dist/play/LocalJam-$name-android.aab"

step "verify the APK signature"
certs="$("$apksigner" verify --print-certs "$apk")"
signer="$(sed -n -E 's/^Signer #1 certificate SHA-256 digest: ([0-9a-f]+).*/\1/p' <<<"$certs")"
[[ "$signer" == "$upload_cert_sha256" ]] ||
  die "the APK is signed by ${signer:-nothing}, not the upload key"
aapt2="$(dirname "$apksigner")/aapt2"
# Not `| head`: under pipefail the closed pipe would kill the script.
badging="$("$aapt2" dump badging "$apk")"
badging="${badging%%$'\n'*}"
[[ "$badging" == *"name='$package_id'"* ]] || die "unexpected package: $badging"
[[ "$badging" == *"versionName='$name'"* ]] || die "unexpected versionName: $badging"
[[ "$badging" == *"versionCode='$build'"* ]] || die "unexpected versionCode: $badging"
echo "signed with the upload key; $package_id $name ($build)"

macos_result="not built"
if [[ $macos -eq 1 ]]; then
  step "macos"
  if (cd "$app" && flutter build macos --release); then
    bundle="$(find "$app/build/macos/Build/Products/Release" -maxdepth 1 -name '*.app' | sort | sed -n 1p)"
    [[ -d "$bundle" ]] || die "no .app in the macOS build output"
    ditto -c -k --sequesterRsrc --keepParent "$bundle" \
      "$dist/upload/LocalJam-$name-macos.zip"
    macos_result="included"
  else
    # Android is the release; a failed desktop build is left out, as in the
    # workflow.
    echo "release: warning: the macOS build failed and is left out" >&2
    macos_result="failed, left out"
  fi
fi

(cd "$dist/upload" && shasum -a 256 -- * >SHA256SUMS.txt)

step "files"
ls -lh "$dist/upload" "$dist/play"

if [[ $dry_run -eq 1 ]]; then
  echo
  echo "Dry run: nothing tagged, nothing uploaded."
  exit 0
fi

# --- release -----------------------------------------------------------------

[[ -z "$(git status --porcelain)" ]] || die "the build left the working tree dirty"

step "tag and release"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
notes="$dist/notes.md"
{
  echo "See [CHANGELOG.md](https://github.com/$repo/blob/$tag/CHANGELOG.md)."
  echo
  echo "- **Android**: install the \`.apk\`. It is signed with a different key than the Google Play build, so the two cannot update each other: uninstall one before installing the other."
  if [[ "$macos_result" == "included" ]]; then
    echo "- **macOS**: unzip and move LocalJam to Applications. The build is not notarized: the first time, right-click the app and choose Open."
  fi
  echo "- **Linux / Windows**: not in this release; build from source (README, \"Building from source\")."
} >"$notes"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "LocalJam $name"
# Only this tag: never --tags or --all.
git push origin "refs/tags/$tag"

flags=(--verify-tag --title "LocalJam $name" --notes-file "$notes")
[[ $publish -eq 1 ]] || flags+=(--draft)
gh release create "$tag" "$dist/upload"/* "${flags[@]}"

echo
if [[ $publish -eq 1 ]]; then
  echo "Published: https://github.com/$repo/releases/tag/$tag"
else
  echo "Draft created. Check its files, then publish it:"
  echo "  gh release edit $tag --draft=false"
fi
echo "For Play: $dist/play/LocalJam-$name-android.aab"
