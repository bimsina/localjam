#!/usr/bin/env bash
# Builds the browser player a host serves to web guests (PROTOCOL.md §1.1,
# docs/design/WEB_GUEST.md "Packaging") and puts it where the host app
# bundles it from.
#
#   tool/build_web_guest.sh           build apps/localjam_web, then replace
#                                     apps/localjam_app/assets/web/ with it
#   tool/build_web_guest.sh --check   only verify the player is in place
#                                     (release scripts run this before
#                                     building the app)
#
# The output is never committed (.gitignore): CI and release builds run this
# first. What is committed is a .gitkeep in every directory the app's
# pubspec declares under assets/web/, because Flutter refuses to build with a
# declared asset directory missing; this script puts them back after each
# copy, so a build leaves git clean.
#
# A pubspec directory entry takes that directory's own files and none of its
# subdirectories', so a directory of the build the pubspec does not list
# would be silently left out of the app — and the page would 404 on it. The
# script names every such directory instead of letting the list rot.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
web_app="$root/apps/localjam_web"
build_out="$web_app/build/web"
dest="$root/apps/localjam_app/assets/web"
pubspec="$root/apps/localjam_app/pubspec.yaml"

# The app refuses a bundle over this (WebGuestBundle, and the CLI's
# --web-dir), so a build over it is a failure here rather than a room with
# no player.
max_bytes=$((64 * 1024 * 1024))

die() {
  echo "build_web_guest: $*" >&2
  exit 1
}

if [[ "${1:-}" == "--check" ]]; then
  [[ $# -eq 1 ]] || die "usage: $0 [--check]"
  if [[ ! -f "$dest/index.html" ]]; then
    die "no web player in apps/localjam_app/assets/web/ (index.html is missing). Run tool/build_web_guest.sh first."
  fi
  echo "build_web_guest: web player present in apps/localjam_app/assets/web/"
  exit 0
fi
[[ $# -eq 0 ]] || die "usage: $0 [--check]"

if [[ ! -d "$web_app" ]]; then
  die "apps/localjam_web does not exist yet: there is no web player to build."
fi
command -v flutter >/dev/null || die "flutter is not on PATH"

# The directories the pubspec declares under assets/web/, relative to it
# ("" for assets/web/ itself), without their trailing slash.
declared_dirs() {
  sed -n -E 's@^[[:space:]]*-[[:space:]]*assets/web/([^[:space:]#]*).*$@\1@p' \
    "$pubspec" | sed -E 's@/$@@'
}

echo "build_web_guest: building apps/localjam_web"
# The page's own build script owns the flags (--base-href /web/,
# --no-web-resources-cdn), deletes the service worker file, scrubs Flutter's unused CDN
# defaults to same-origin paths, prunes what a dart2js build never loads
# (skwasm/wimp, webparagraph, *.symbols) and fails if
# anything still names an internet host (D8).
"$web_app/tool/build.sh"
[[ -f "$build_out/index.html" ]] ||
  die "the build finished without $build_out/index.html"

rm -rf "$dest"
mkdir -p "$dest"
cp -R "$build_out/." "$dest/"

# The tool's own bookkeeping, not part of the page (build.sh already pruned
# everything else no guest fetches).
rm -f "$dest/.last_build_id"

# Declared directories this build gave no files of their own (apart from
# assets/web/ itself, which always has index.html): a stale entry, and a
# placeholder that keeps an empty directory in the app for nothing.
built_dirs="$(find "$dest" -type f -exec dirname {} \; | sort -u)"
stale=()
while IFS= read -r dir; do
  if ! grep -qxF -- "$dest${dir:+/$dir}" <<<"$built_dirs"; then
    stale+=("$dir")
  fi
done < <(declared_dirs)

# The committed placeholders, back in every declared directory.
while IFS= read -r dir; do
  mkdir -p "$dest/$dir"
  : >"$dest/${dir:+$dir/}.gitkeep"
done < <(declared_dirs)

# Every directory of the build with files of its own must be declared.
declared="$(declared_dirs)"
undeclared=()
while IFS= read -r dir; do
  rel="${dir#"$dest"}"
  rel="${rel#/}"
  if ! grep -qxF -- "$rel" <<<"$declared"; then
    undeclared+=("$rel")
  fi
done < <(find "$dest" -type f ! -name '.gitkeep' -exec dirname {} \; | sort -u)

files="$(find "$dest" -type f ! -name '.gitkeep' | wc -l | tr -d ' ')"
bytes="$(find "$dest" -type f ! -name '.gitkeep' -exec cat {} + | wc -c | tr -d ' ')"
echo "build_web_guest: copied $files files, $bytes bytes ($((bytes / 1024)) KB) into apps/localjam_app/assets/web/"

if ((${#undeclared[@]} > 0)); then
  {
    echo
    echo "build_web_guest: WARNING: these directories of the build are not in"
    echo "apps/localjam_app/pubspec.yaml, so the app will not bundle their files"
    echo "and the page will 404 on them. Add them under flutter.assets, and a"
    echo ".gitkeep in each, then run this again:"
    for rel in "${undeclared[@]}"; do
      echo "    - assets/web/${rel:+$rel/}"
    done
    echo
  } >&2
fi

if ((${#stale[@]} > 0)); then
  {
    echo
    echo "build_web_guest: WARNING: the build no longer produces these directories"
    echo "that apps/localjam_app/pubspec.yaml declares. Remove them from"
    echo "flutter.assets, and their .gitkeep:"
    for rel in "${stale[@]}"; do
      echo "    - assets/web/${rel:+$rel/}"
    done
    echo
  } >&2
fi

if ((bytes > max_bytes)); then
  die "the player is $bytes bytes, over the $((max_bytes / 1024 / 1024)) MB a host will load"
fi
