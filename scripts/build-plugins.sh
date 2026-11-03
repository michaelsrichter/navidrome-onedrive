#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_config="$repo_root/infra/images.json"
plugin_config="$repo_root/infra/plugins.json"
output_dir="$repo_root/build/plugins"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "$temp_dir"' EXIT

for command in cmp curl go jq patch sha256sum tar unzip zip; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

navidrome_version="$(jq -er '.navidromeVersion' "$image_config")"
pdk_version="$(jq -er '.navidromePdk.version' "$plugin_config")"
pdk_commit="$(jq -er '.navidromePdk.commit' "$plugin_config")"
lyrics_repo="$(jq -er '.lyrics.repository' "$plugin_config")"
lyrics_version="$(jq -er '.lyrics.version' "$plugin_config")"
lyrics_commit="$(jq -er '.lyrics.commit' "$plugin_config")"
lyrics_asset="$(jq -er '.lyrics.asset' "$plugin_config")"
lyrics_sha256="$(jq -er '.lyrics.sha256' "$plugin_config")"
caa_repo="$(jq -er '.coverartarchive.repository' "$plugin_config")"
caa_commit="$(jq -er '.coverartarchive.commit' "$plugin_config")"

if [[ "$navidrome_version" != "$pdk_version" ]]; then
  echo "Plugin PDK version $pdk_version must match Navidrome image version $navidrome_version." >&2
  exit 1
fi

mkdir -p "$output_dir"
rm -f "$output_dir/nd-lyrics.ndp" "$output_dir/coverartarchive.ndp" "$output_dir/audiomuseai.ndp"

curl --fail --location --silent --show-error \
  "https://github.com/${lyrics_repo}/releases/download/${lyrics_version}/${lyrics_asset}" \
  --output "$temp_dir/$lyrics_asset"
printf '%s  %s\n' "$lyrics_sha256" "$temp_dir/$lyrics_asset" | sha256sum --check
unzip -tq "$temp_dir/$lyrics_asset"
curl --fail --location --silent --show-error \
  "https://raw.githubusercontent.com/${lyrics_repo}/${lyrics_commit}/LICENSE" \
  --output "$temp_dir/nd-lyrics-LICENSE"
if ! cmp --silent "$temp_dir/nd-lyrics-LICENSE" "$repo_root/licenses/nd-lyrics-MIT.txt"; then
  echo "The pinned nd-lyrics source license does not match licenses/nd-lyrics-MIT.txt." >&2
  exit 1
fi
cp "$temp_dir/$lyrics_asset" "$output_dir/nd-lyrics.ndp"

mkdir -p "$temp_dir/navidrome" "$temp_dir/coverartarchive"
curl --fail --location --silent --show-error \
  "https://codeload.github.com/navidrome/navidrome/tar.gz/${pdk_commit}" \
  --output "$temp_dir/navidrome.tar.gz"
tar -xzf "$temp_dir/navidrome.tar.gz" --strip-components=1 -C "$temp_dir/navidrome"

curl --fail --location --silent --show-error \
  "https://codeload.github.com/${caa_repo}/tar.gz/${caa_commit}" \
  --output "$temp_dir/coverartarchive.tar.gz"
tar -xzf "$temp_dir/coverartarchive.tar.gz" --strip-components=1 -C "$temp_dir/coverartarchive"
if ! cmp --silent "$temp_dir/coverartarchive/LICENSE" "$repo_root/licenses/coverartarchive-MIT.txt"; then
  echo "The pinned coverartarchive source license does not match licenses/coverartarchive-MIT.txt." >&2
  exit 1
fi

mkdir -p "$temp_dir/navidrome/ui/src/genre"
cp "$repo_root/patches/navidrome/genre/GenreList.jsx" \
  "$repo_root/patches/navidrome/genre/index.jsx" \
  "$temp_dir/navidrome/ui/src/genre/"
patch --batch --forward -p1 -d "$temp_dir/navidrome" \
  < "$repo_root/patches/navidrome-v0.64.2-genres.patch"

build_dir="$temp_dir/navidrome/plugins/examples/coverartarchive-go"
if [[ ! -d "$temp_dir/navidrome/plugins/pdk/go" ]]; then
  echo "Navidrome source at $pdk_commit does not contain the expected Go plugin PDK." >&2
  exit 1
fi
mkdir -p "$build_dir"
cp "$temp_dir/coverartarchive/main.go" \
  "$temp_dir/coverartarchive/manifest.json" \
  "$temp_dir/coverartarchive/go.mod" \
  "$temp_dir/coverartarchive/go.sum" \
  "$build_dir/"

(
  cd "$build_dir"
  GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -trimpath -mod=readonly -o plugin.wasm .
  zip -q -j "$output_dir/coverartarchive.ndp" manifest.json plugin.wasm
)
unzip -tq "$output_dir/coverartarchive.ndp"

source_output_dir="$repo_root/build/navidrome-src"
if [[ -e "$source_output_dir" ]]; then
  rm -rf -- "$source_output_dir"
fi
mkdir -p "$source_output_dir"
cp -a "$temp_dir/navidrome/." "$source_output_dir/"
mkdir -p "$source_output_dir/build/plugins" "$source_output_dir/licenses"
cp "$output_dir/nd-lyrics.ndp" "$output_dir/coverartarchive.ndp" \
  "$source_output_dir/build/plugins/"
cp "$repo_root/licenses/nd-lyrics-MIT.txt" \
  "$repo_root/licenses/coverartarchive-MIT.txt" \
  "$source_output_dir/licenses/"

source_output_dir="$repo_root/build/navidrome-src"
if [[ -e "$source_output_dir" ]]; then
  rm -rf -- "$source_output_dir"
fi
mkdir -p "$source_output_dir"
cp -a "$temp_dir/navidrome/." "$source_output_dir/"
mkdir -p "$source_output_dir/build/plugins" "$source_output_dir/licenses"
cp "$output_dir/nd-lyrics.ndp" "$output_dir/coverartarchive.ndp" \
  "$source_output_dir/build/plugins/"
cp "$repo_root/licenses/nd-lyrics-MIT.txt" \
  "$repo_root/licenses/coverartarchive-MIT.txt" \
  "$source_output_dir/licenses/"

printf 'Built and verified pinned plugins:\n'
printf '  nd-lyrics %s\n' "$lyrics_version"
printf '  coverartarchive %s against Navidrome %s PDK\n' \
  "$(jq -er '.coverartarchive.version' "$plugin_config")" "$navidrome_version"
printf 'Prepared patched Navidrome build context at %s\n' "$source_output_dir"
