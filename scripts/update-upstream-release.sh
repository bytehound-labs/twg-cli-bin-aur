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

for command in awk curl jq makepkg mktemp python sed sha256sum sort; do
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
	local sums_file="$1"
	local target="$2"

	awk -v target="$target" '
		{
			name = $2
			sub(/^\*/, "", name)
			sub(/\r$/, "", name)
			if (name == target) {
				print $1
				exit
			}
		}
	' "$sums_file"
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
latest_x64_sha="$(checksum_for "$sums_path" "$x64_name")"
latest_arm64_sha="$(checksum_for "$sums_path" "$arm64_name")"
latest_license_sha="$(sha256sum "$license_path" | awk '{print $1}')"
validate_checksum "$x64_name" "$latest_x64_sha"
validate_checksum "$arm64_name" "$latest_arm64_sha"
validate_checksum LICENSE "$latest_license_sha"

downloaded_x64="$workdir/$x64_name"
download "$x64_url" "$downloaded_x64"
printf '%s  %s\n' "$latest_x64_sha" "$downloaded_x64" |
	sha256sum --check --status

latest_bunver="$(
	python - "$downloaded_x64" <<'PY'
import re
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
match = re.search(
    rb"Bun v([0-9]+\.[0-9]+\.[0-9]+) \(([^()\x00]+)\) Linux x64(?: \(baseline\))?",
    data,
)
if match is None:
    raise SystemExit("TWG x86_64 artifact does not contain a Bun version marker")
print(match.group(1).decode("ascii"))
PY
)"
if [[ ! "$latest_bunver" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
	echo "Unsupported Bun version in TWG x86_64 artifact: $latest_bunver" >&2
	exit 1
fi

bun_name="bun-linux-x64-baseline-v${latest_bunver}.zip"
bun_url="https://github.com/oven-sh/bun/releases/download/bun-v${latest_bunver}/bun-linux-x64-baseline.zip"
bun_sums_url="https://github.com/oven-sh/bun/releases/download/bun-v${latest_bunver}/SHASUMS256.txt"
bun_sums_path="$workdir/SHASUMS256-bun"
downloaded_bun="$workdir/$bun_name"
download "$bun_sums_url" "$bun_sums_path"
latest_bun_sha="$(checksum_for "$bun_sums_path" 'bun-linux-x64-baseline.zip')"
validate_checksum "$bun_name" "$latest_bun_sha"
download "$bun_url" "$downloaded_bun"
printf '%s  %s\n' "$latest_bun_sha" "$downloaded_bun" |
	sha256sum --check --status

python "$repo_root/twg-baseline-patcher.py" \
	"$downloaded_x64" \
	"$downloaded_bun" \
	"$workdir/twg-linux-x64-v${latest_pkgver}-baseline"

unset pkgname pkgver pkgrel _bunver arch source source_x86_64 source_aarch64
unset sha256sums sha256sums_x86_64 sha256sums_aarch64
# shellcheck disable=SC1091
source ./PKGBUILD

if [[ "$pkgname" != twg-cli-bin || "${#source[@]}" -ne 2 ||
	"${#source_x86_64[@]}" -ne 2 || "${#source_aarch64[@]}" -ne 1 ||
	"${#sha256sums[@]}" -ne 2 || "${#sha256sums_x86_64[@]}" -ne 2 ||
	"${#sha256sums_aarch64[@]}" -ne 1 ]]; then
	echo "PKGBUILD has unexpected source metadata" >&2
	exit 1
fi

current_pkgver="$pkgver"
current_pkgrel="$pkgrel"
current_bunver="$_bunver"
current_patcher_sha="${sha256sums[0]}"
current_license_sha="${sha256sums[1]}"
current_x64_sha="${sha256sums_x86_64[0]}"
current_bun_sha="${sha256sums_x86_64[1]}"
current_arm64_sha="${sha256sums_aarch64[0]}"
actual_patcher_sha="$(sha256sum "$repo_root/twg-baseline-patcher.py" | awk '{print $1}')"

if [[ ! "$current_pkgrel" =~ ^[0-9]+$ || ! "$current_bunver" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
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
if [[ "$latest_bunver" != "$current_bunver" ||
	"$latest_license_sha" != "$current_license_sha" ||
	"$actual_patcher_sha" != "$current_patcher_sha" ||
	"$latest_x64_sha" != "$current_x64_sha" ||
	"$latest_bun_sha" != "$current_bun_sha" ||
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
echo "Bun version:       ${latest_bunver}"
echo "x86_64 SHA-256:   ${latest_x64_sha}"
echo "Bun baseline SHA:  ${latest_bun_sha}"
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

cp PKGBUILD "$update_dir/PKGBUILD"
python - "$update_dir/PKGBUILD" \
	"$latest_pkgver" "$next_pkgrel" "$latest_bunver" \
	"$actual_patcher_sha" "$latest_license_sha" "$latest_x64_sha" \
	"$latest_bun_sha" "$latest_arm64_sha" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
pkgver, pkgrel, bunver = sys.argv[2:5]
patcher_sha, license_sha, x64_sha, bun_sha, arm64_sha = sys.argv[5:10]
text = path.read_text()

replacements = (
    (r"^pkgver=[^\n]*$", f"pkgver={pkgver}"),
    (r"^pkgrel=[^\n]*$", f"pkgrel={pkgrel}"),
    (r"^_bunver=[^\n]*$", f"_bunver={bunver}"),
    (
        r"^source=\(\n.*?^\)",
        "source=(\n"
        "\t'twg-baseline-patcher.py'\n"
        "\t'twg-cli-LICENSE::https://raw.githubusercontent.com/atlassian/twg-cli/main/LICENSE'\n"
        ")",
    ),
    (
        r"^source_x86_64=[^\n]*(?:\nsource_x86_64\+=[^\n]*)?",
        f'source_x86_64=("twg-linux-x64-v${{pkgver}}::https://teamwork-graph.atlassian.com/cli/twg-linux-x64-v${{pkgver}}"'
        f' "bun-linux-x64-baseline-v${{_bunver}}.zip::https://github.com/oven-sh/bun/releases/download/bun-v${{_bunver}}/bun-linux-x64-baseline.zip")',
    ),
    (
        r"^source_aarch64=[^\n]*$",
        'source_aarch64=("twg-linux-arm64-v${pkgver}::https://teamwork-graph.atlassian.com/cli/twg-linux-arm64-v${pkgver}")',
    ),
    (
        r"^sha256sums=\(\n.*?^\)",
        f"sha256sums=(\n\t'{patcher_sha}'\n\t'{license_sha}'\n)",
    ),
    (
        r"^sha256sums_x86_64=\(\n.*?^\)",
        f"sha256sums_x86_64=(\n\t'{x64_sha}'\n\t'{bun_sha}'\n)",
    ),
    (
        r"^sha256sums_aarch64=[^\n]*$",
        f"sha256sums_aarch64=('{arm64_sha}')",
    ),
)

for pattern, replacement in replacements:
    updated, count = re.subn(
        pattern, replacement, text, count=1, flags=re.MULTILINE | re.DOTALL
    )
    if count != 1:
        raise SystemExit(f"could not update PKGBUILD block: {pattern}")
    text = updated

path.write_text(text)
PY

(
	cd "$update_dir"
	makepkg --printsrcinfo -p PKGBUILD
) > "$update_dir/.SRCINFO"
mv "$update_dir/PKGBUILD" PKGBUILD
mv "$update_dir/.SRCINFO" .SRCINFO

echo "Updated PKGBUILD and .SRCINFO."
