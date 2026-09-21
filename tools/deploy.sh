#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_root/reframework/autorun/monster_hp_overlay.lua"

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

if [[ ! -f "$source_file" ]]; then
	echo "Source file was not found: $source_file" >&2
	exit 1
fi

mkdir -p "$target_dir"
cp "$source_file" "$target_dir/monster_hp_overlay.lua"
printf 'Deployed monster_hp_overlay.lua to %s\n' "$target_dir"
