#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: update-upstream-release.sh [--dry-run]

Update PKGBUILD and .SRCINFO from Atlassian's stable TWG CLI manifest.
EOF
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "Missing required command: $1" >&2
		exit 1
	fi
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dry_run=false
while (($# > 0)); do
	case "$1" in
		--dry-run)
			dry_run=true
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		*)
			usage >&2
			exit 1
			;;
	esac
done

for command in awk curl git jq makepkg mktemp sed sha256sum sort; do
	require_command "$command"
done

public_cdn_base='https://teamwork-graph.atlassian.com/cli'
manifest_url="${public_cdn_base}/manifest.json"
license_url='https://raw.githubusercontent.com/atlassian/twg-cli/main/LICENSE'

workdir="$(mktemp -d)"
cleanup() {
	rm -rf "$workdir"
}
trap cleanup EXIT

download() {
	local url="$1"
	local destination="$2"

	curl --fail --silent --show-error --location --retry 2 \
		--proto '=https' --tlsv1.2 -o "$destination" "$url"
}

manifest_path="$workdir/manifest.json"
sums_path="$workdir/SHA256SUMS"
license_path="$workdir/LICENSE"
download "$manifest_url" "$manifest_path"

manifest_channel="$(jq -er '.channel // empty' "$manifest_path")"
latest_pkgver="$(jq -er '.version // empty' "$manifest_path")"
x64_url="$(jq -er '.assets["linux-x64"].url // empty' "$manifest_path")"
arm64_url="$(jq -er '.assets["linux-arm64"].url // empty' "$manifest_path")"
checksums_url="$(jq -er '.checksumsUrl // empty' "$manifest_path")"

if [[ "$manifest_channel" != stable ]]; then
	echo "Unexpected TWG release channel: $manifest_channel" >&2
	exit 1
fi

if [[ ! "$latest_pkgver" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
	echo "Unsupported TWG version in stable manifest: $latest_pkgver" >&2
	exit 1
fi

expected_x64_url="${public_cdn_base}/twg-linux-x64-v${latest_pkgver}"
expected_arm64_url="${public_cdn_base}/twg-linux-arm64-v${latest_pkgver}"
expected_checksums_url="${public_cdn_base}/SHA256SUMS-v${latest_pkgver}"

if [[ "$x64_url" != "$expected_x64_url" ]]; then
	echo "Unexpected x86_64 asset URL: $x64_url" >&2
	exit 1
fi
if [[ "$arm64_url" != "$expected_arm64_url" ]]; then
	echo "Unexpected aarch64 asset URL: $arm64_url" >&2
	exit 1
fi
if [[ "$checksums_url" != "$expected_checksums_url" ]]; then
	echo "Unexpected checksum URL: $checksums_url" >&2
	exit 1
fi

download "$checksums_url" "$sums_path"
download "$license_url" "$license_path"

checksum_for() {
	local filename="$1"
	awk -v target="$filename" '
		{
			name = $2
			sub(/^\*/, "", name)
			sub(/\r$/, "", name)
			if (name == target) {
				print $1
				exit
			}
		}
	' "$sums_path"
}

validate_checksum() {
	local name="$1"
	local checksum="$2"

	if [[ ! "$checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
		echo "Missing or invalid SHA-256 for $name" >&2
		exit 1
	fi
}

x64_name="twg-linux-x64-v${latest_pkgver}"
arm64_name="twg-linux-arm64-v${latest_pkgver}"
latest_x64_sha="$(checksum_for "$x64_name")"
latest_arm64_sha="$(checksum_for "$arm64_name")"
latest_license_sha="$(sha256sum "$license_path" | awk '{print $1}')"
validate_checksum "$x64_name" "$latest_x64_sha"
validate_checksum "$arm64_name" "$latest_arm64_sha"
validate_checksum LICENSE "$latest_license_sha"

current_pkgver="$(sed -nE 's/^pkgver=([^[:space:]]+).*$/\1/p' PKGBUILD | head -n 1)"
current_pkgrel="$(sed -nE 's/^pkgrel=([^[:space:]]+).*$/\1/p' PKGBUILD | head -n 1)"
current_license_sha="$(sed -nE "s/^sha256sums=\\('([^']+)'\\).*$/\\1/p" PKGBUILD | head -n 1)"
current_x64_sha="$(sed -nE "s/^sha256sums_x86_64=\\('([^']+)'\\).*$/\\1/p" PKGBUILD | head -n 1)"
current_arm64_sha="$(sed -nE "s/^sha256sums_aarch64=\\('([^']+)'\\).*$/\\1/p" PKGBUILD | head -n 1)"

if [[ -z "$current_pkgver" || -z "$current_pkgrel" || -z "$current_license_sha" ||
	-z "$current_x64_sha" || -z "$current_arm64_sha" ]]; then
	echo "Failed to parse package metadata from PKGBUILD" >&2
	exit 1
fi

if [[ ! "$current_pkgrel" =~ ^[0-9]+$ ]]; then
	echo "pkgrel must be an integer: $current_pkgrel" >&2
	exit 1
fi

if [[ "$latest_pkgver" != "$current_pkgver" ]]; then
	highest_version="$(printf '%s\n' "$current_pkgver" "$latest_pkgver" | sort -V | tail -n 1)"
	if [[ "$highest_version" != "$latest_pkgver" ]]; then
		echo "Stable manifest version moved backwards: $current_pkgver -> $latest_pkgver" >&2
		exit 1
	fi
fi

artifact_changed=false
if [[ "$latest_license_sha" != "$current_license_sha" ||
	"$latest_x64_sha" != "$current_x64_sha" ||
	"$latest_arm64_sha" != "$current_arm64_sha" ]]; then
	artifact_changed=true
fi

next_pkgrel="$current_pkgrel"
if [[ "$latest_pkgver" != "$current_pkgver" ]]; then
	next_pkgrel=1
elif [[ "$artifact_changed" == true ]]; then
	next_pkgrel=$((current_pkgrel + 1))
fi

echo "Current version: ${current_pkgver}-${current_pkgrel}"
echo "Latest version:  ${latest_pkgver}-${next_pkgrel}"
echo "x86_64 SHA-256:   ${latest_x64_sha}"
echo "aarch64 SHA-256:  ${latest_arm64_sha}"
echo "License SHA-256:  ${latest_license_sha}"

if [[ "$latest_pkgver" == "$current_pkgver" && "$artifact_changed" == false ]]; then
	echo "No update needed."
	exit 0
fi

if [[ "$dry_run" == true ]]; then
	exit 0
fi

update_dir="$(mktemp -d "$repo_root/.twg-update.XXXXXX")"
trap 'rm -rf "$workdir" "$update_dir"' EXIT

sed \
	-e "s/^pkgver=.*/pkgver=${latest_pkgver}/" \
	-e "s/^pkgrel=.*/pkgrel=${next_pkgrel}/" \
	-e "s/^sha256sums=.*/sha256sums=('${latest_license_sha}')/" \
	-e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('${latest_x64_sha}')/" \
	-e "s/^sha256sums_aarch64=.*/sha256sums_aarch64=('${latest_arm64_sha}')/" \
	PKGBUILD > "$update_dir/PKGBUILD"

makepkg --printsrcinfo -p "$update_dir/PKGBUILD" > "$update_dir/.SRCINFO"
mv "$update_dir/PKGBUILD" PKGBUILD
mv "$update_dir/.SRCINFO" .SRCINFO

echo "Updated PKGBUILD and .SRCINFO."
