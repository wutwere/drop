#!/usr/bin/env bash

set -euo pipefail

readonly ROBLOX_DEFINITIONS_URL="https://luau-lsp.pages.dev/globalTypes.None.d.luau"

is_verbose() {
	[ "${VERBOSE:-0}" = "1" ] || [ "${CI_VERBOSE:-0}" = "1" ]
}

print_step() {
	local project="$1"
	local step="$2"
	printf '[%s] %s\n' "$project" "$step"
}

run_quiet_step() {
	local project="$1"
	local step="$2"
	local output_path="$3"
	shift 3

	local command_exit=0

	print_step "$project" "$step"

	if is_verbose; then
		"$@"
		return 0
	fi

	set +e
	"$@" >"$output_path" 2>&1
	command_exit=$?
	set -e

	if [ "$command_exit" -ne 0 ]; then
		printf '[%s] %s failed\n' "$project" "$step" >&2
		cat "$output_path" >&2
		return "$command_exit"
	fi

	return 0
}

download_roblox_definitions() {
	local output_path="$1"
	curl --fail --silent --show-error --location "$ROBLOX_DEFINITIONS_URL" --output "$output_path"
}

has_package_dir() {
	local project="$1"
	local directory_name="$2"
	[ -d "$project/$directory_name" ]
}

has_any_package_dir() {
	local project="$1"
	has_package_dir "$project" "Packages" || has_package_dir "$project" "ServerPackages"
}
