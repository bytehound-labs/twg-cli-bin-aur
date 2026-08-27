#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: validate-package.sh [--build]

Validate package metadata, both Linux artifacts, and optionally build the package.
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

build_package=false
while (($# > 0)); do
	case "$1" in
		--build)
			build_package=true
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

for command in awk bash bsdtar curl diff file grep makepkg namcap python sed sha256sum sort; do
	require_command "$command"
done

for script in scripts/*.sh; do
	bash -n "$script"
done

unset pkgname pkgver pkgrel _bunver arch source source_x86_64 source_aarch64
unset sha256sums sha256sums_x86_64 sha256sums_aarch64
# shellcheck disable=SC1091
source ./PKGBUILD

if [[ "$pkgname" != twg-cli-bin ]]; then
	echo "Unexpected package name: $pkgname" >&2
	exit 1
fi
if [[ "$pkgver" != "$(
	sed -nE 's/^pkgver=([^[:space:]]+).*$/\1/p' PKGBUILD | head -n 1
)" ]]; then
	echo "PKGBUILD version parsing is inconsistent" >&2
	exit 1
fi
if [[ "${arch[*]}" != 'x86_64 aarch64' ]]; then
	echo "Unexpected package architectures: ${arch[*]}" >&2
	exit 1
fi
if [[ "${#source[@]}" -ne 2 || "${#source_x86_64[@]}" -ne 2 ||
	"${#source_aarch64[@]}" -ne 1 ]]; then
	echo "Expected two common sources, two x86_64 sources, and one aarch64 source" >&2
	exit 1
fi
if [[ "${#sha256sums[@]}" -ne 2 || "${#sha256sums_x86_64[@]}" -ne 2 ||
	"${#sha256sums_aarch64[@]}" -ne 1 ]]; then
	echo "Expected checksums for every package source" >&2
	exit 1
fi

patcher_name="${source[0]%%::*}"
license_url="${source[1]#*::}"
x64_name="${source_x86_64[0]%%::*}"
x64_url="${source_x86_64[0]#*::}"
bun_name="${source_x86_64[1]%%::*}"
bun_url="${source_x86_64[1]#*::}"
arm64_name="${source_aarch64[0]%%::*}"
arm64_url="${source_aarch64[0]#*::}"
case "$(uname -m)" in
	x86_64)
		host_carch=x86_64
		;;
	aarch64|arm64)
		host_carch=aarch64
		;;
	*)
		host_carch=unknown
		;;
esac

[[ "$patcher_name" == 'twg-baseline-patcher.py' ]] ||
	{ echo "Unexpected baseline patcher source: $patcher_name" >&2; exit 1; }
[[ "$license_url" == 'https://raw.githubusercontent.com/atlassian/twg-cli/main/LICENSE' ]] ||
	{ echo "Unexpected license URL: $license_url" >&2; exit 1; }
[[ "$x64_url" == "https://teamwork-graph.atlassian.com/cli/twg-linux-x64-v${pkgver}" ]] ||
	{ echo "Unexpected x86_64 URL: $x64_url" >&2; exit 1; }
[[ "$_bunver" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] ||
	{ echo "Invalid Bun runtime version: $_bunver" >&2; exit 1; }
[[ "$bun_name" == "bun-linux-x64-baseline-v${_bunver}.zip" ]] ||
	{ echo "Unexpected Bun baseline source name: $bun_name" >&2; exit 1; }
[[ "$bun_url" == "https://github.com/oven-sh/bun/releases/download/bun-v${_bunver}/bun-linux-x64-baseline.zip" ]] ||
	{ echo "Unexpected Bun baseline URL: $bun_url" >&2; exit 1; }
[[ "$arm64_url" == "https://teamwork-graph.atlassian.com/cli/twg-linux-arm64-v${pkgver}" ]] ||
	{ echo "Unexpected aarch64 URL: $arm64_url" >&2; exit 1; }

if [[ ! "${sha256sums[0]}" =~ ^[[:xdigit:]]{64}$ ||
	! "${sha256sums[1]}" =~ ^[[:xdigit:]]{64}$ ||
	! "${sha256sums_x86_64[0]}" =~ ^[[:xdigit:]]{64}$ ||
	! "${sha256sums_x86_64[1]}" =~ ^[[:xdigit:]]{64}$ ||
	! "${sha256sums_aarch64[0]}" =~ ^[[:xdigit:]]{64}$ ]]; then
	echo "PKGBUILD contains an invalid SHA-256 checksum" >&2
	exit 1
fi

generated_srcinfo="$(mktemp)"
workdir="$(mktemp -d)"
cleanup() {
	rm -f "$generated_srcinfo"
	rm -rf "$workdir"
}
trap cleanup EXIT

makepkg --printsrcinfo > "$generated_srcinfo"
diff -u .SRCINFO "$generated_srcinfo"

download_and_verify() {
	local name="$1"
	local url="$2"
	local checksum="$3"
	local destination="$workdir/$name"

	curl --fail --silent --show-error --location --retry 2 \
		--proto '=https' --tlsv1.2 -o "$destination" "$url"
	printf '%s  %s\n' "$checksum" "$destination" | sha256sum --check --status
	echo "Verified $name"
}

patcher_sha="$(sha256sum "$repo_root/$patcher_name" | awk '{print $1}')"
[[ "$patcher_sha" == "${sha256sums[0]}" ]] ||
	{ echo "Baseline patcher checksum does not match PKGBUILD" >&2; exit 1; }

download_and_verify "${source[1]%%::*}" "$license_url" "${sha256sums[1]}"
download_and_verify "$x64_name" "$x64_url" "${sha256sums_x86_64[0]}"
download_and_verify "$bun_name" "$bun_url" "${sha256sums_x86_64[1]}"
download_and_verify "$arm64_name" "$arm64_url" "${sha256sums_aarch64[0]}"

x64_file_type="$(file -b "$workdir/$x64_name")"
arm64_file_type="$(file -b "$workdir/$arm64_name")"
grep -Eq 'ELF 64-bit.*x86-64' <<<"$x64_file_type" ||
	{ echo "x86_64 artifact is not an x86-64 ELF: $x64_file_type" >&2; exit 1; }
grep -Eq 'ELF 64-bit.*ARM aarch64' <<<"$arm64_file_type" ||
	{ echo "aarch64 artifact is not an ARM ELF: $arm64_file_type" >&2; exit 1; }

patched_x64="$workdir/twg-linux-x64-v${pkgver}-baseline"
python "$repo_root/$patcher_name" \
	"$workdir/$x64_name" \
	"$workdir/$bun_name" \
	"$patched_x64"
patched_x64_file_type="$(file -b "$patched_x64")"
grep -Eq 'ELF 64-bit.*x86-64' <<<"$patched_x64_file_type" ||
	{ echo "Patched x86_64 artifact is not an x86-64 ELF: $patched_x64_file_type" >&2; exit 1; }

makepkg --verifysource --force --nocolor
namcap PKGBUILD

if [[ "${RUN_SMOKE_TEST:-1}" != 0 ]]; then
	case "$host_carch" in
		x86_64)
			smoke_binary="$patched_x64"
			;;
		aarch64)
			smoke_binary="$workdir/$arm64_name"
			;;
		*)
			smoke_binary=''
			;;
	esac

	if [[ -n "$smoke_binary" ]]; then
		chmod +x "$smoke_binary"
		version_output="$(
			DO_NOT_TRACK=1 "$smoke_binary" --version 2>&1
		)" || {
			status=$?
			echo "TWG version smoke test failed with status $status" >&2
			echo "$version_output" >&2
			exit "$status"
		}
		grep -Fq "$pkgver" <<<"$version_output" ||
			{ echo "TWG version output did not contain $pkgver" >&2; exit 1; }
	fi
fi

if [[ "$build_package" == true ]]; then
	built_package="$(makepkg --packagelist --nobuild --nodeps --noconfirm --nocolor | head -n 1)"
	makepkg --cleanbuild --force --nodeps --noconfirm --nocolor
	namcap "$built_package"

	if [[ "${RUN_SMOKE_TEST:-1}" != 0 && "$host_carch" != unknown ]]; then
		packaged_binary="$workdir/twg-packaged"
		bsdtar -xOf "$built_package" usr/bin/twg > "$packaged_binary"
		chmod +x "$packaged_binary"
		packaged_version="$(
			DO_NOT_TRACK=1 "$packaged_binary" --version 2>&1
		)" || {
			status=$?
			echo "Packaged TWG smoke test failed with status $status" >&2
			echo "$packaged_version" >&2
			exit "$status"
		}
		grep -Fq "$pkgver" <<<"$packaged_version" ||
			{ echo "Packaged TWG version output did not contain $pkgver" >&2; exit 1; }
	fi

	mapfile -t package_files < <(
		bsdtar -tf "$built_package" |
			sed -E '/\/$/d;/^\.(BUILDINFO|MTREE|PKGINFO)$/d' |
			sort
	)
	expected_files=(
		'usr/bin/twg'
		"usr/share/licenses/$pkgname/LICENSE"
	)
	diff -u \
		<(printf '%s\n' "${expected_files[@]}" | sort) \
		<(printf '%s\n' "${package_files[@]}")
fi

echo "Package validation succeeded."
