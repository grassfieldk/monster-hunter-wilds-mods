#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/reframework/autorun/monster_hp_overlay.lua"
source_image_dir="$repo_root/reframework/images/monster_hp_overlay"
source_font="/mnt/c/Windows/Fonts/NotoSansJP-Medium.otf"

to_wsl_path() {
	local value="$1"
	if [[ "$value" =~ ^([A-Za-z]):/(.*)$ ]]; then
		local drive="${BASH_REMATCH[1],,}"
		echo "/mnt/$drive/${BASH_REMATCH[2]}"
	else
		echo "$value"
	fi
}

if [[ -n "${REFRAMEWORK_AUTORUN_DIR:-}" ]]; then
	target_dir="$(to_wsl_path "$REFRAMEWORK_AUTORUN_DIR")"
elif [[ -n "${MH_WILDS_GAME_DIR:-}" ]]; then
	target_dir="$(to_wsl_path "$MH_WILDS_GAME_DIR")/reframework/autorun"
else
	echo 'Set MH_WILDS_GAME_DIR or REFRAMEWORK_AUTORUN_DIR in .env before deploying.' >&2
	exit 1
fi

target_font_dir="$(dirname "$target_dir")/fonts"
target_image_dir="$(dirname "$target_dir")/images/monster_hp_overlay"

if [[ ! -f "$source_file" ]]; then
	echo "Source file was not found: $source_file" >&2
	exit 1
fi

if [[ ! -d "$source_image_dir" ]]; thenｎ
	echo "Image directory was not found: $source_image_dir" >&2
	exit 1
fi

if [[ ! -f "$source_font" ]]; then
	echo "Japanese font was not found: $source_font" >&2
	exit 1
fi

mkdir -p "$target_dir"
mkdir -p "$target_image_dir"
mkdir -p "$target_font_dir"
cp "$source_file" "$target_dir/monster_hp_overlay.lua"
cp -R -n "$source_image_dir/." "$target_image_dir/"
cp "$source_font" "$target_font_dir/NotoSansJP-Medium.otf"
printf 'Deployed monster_hp_overlay.lua to %s\n' "$target_dir"
printf 'Deployed monster_hp_overlay images to %s\n' "$target_image_dir"
printf 'Deployed NotoSansJP-Medium.otf to %s\n' "$target_font_dir"
