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

for command in awk bash bsdtar curl diff file grep makepkg namcap sed sha256sum sort; do
	require_command "$command"
done

for script in scripts/*.sh; do
	bash -n "$script"
done

unset pkgname pkgver pkgrel arch source source_x86_64 source_aarch64
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
if [[ "${#source[@]}" -ne 1 || "${#source_x86_64[@]}" -ne 1 || "${#source_aarch64[@]}" -ne 1 ]]; then
	echo "Expected one common source and one source per architecture" >&2
	exit 1
fi
if [[ "${#sha256sums[@]}" -ne 1 || "${#sha256sums_x86_64[@]}" -ne 1 ||
	"${#sha256sums_aarch64[@]}" -ne 1 ]]; then
	echo "Expected one checksum per package source" >&2
	exit 1
fi

license_url="${source[0]#*::}"
x64_name="${source_x86_64[0]%%::*}"
x64_url="${source_x86_64[0]#*::}"
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

[[ "$license_url" == 'https://raw.githubusercontent.com/atlassian/twg-cli/main/LICENSE' ]] ||
	{ echo "Unexpected license URL: $license_url" >&2; exit 1; }
[[ "$x64_url" == "https://teamwork-graph.atlassian.com/cli/twg-linux-x64-v${pkgver}" ]] ||
	{ echo "Unexpected x86_64 URL: $x64_url" >&2; exit 1; }
[[ "$arm64_url" == "https://teamwork-graph.atlassian.com/cli/twg-linux-arm64-v${pkgver}" ]] ||
	{ echo "Unexpected aarch64 URL: $arm64_url" >&2; exit 1; }

if [[ ! "${sha256sums[0]}" =~ ^[[:xdigit:]]{64}$ ||
	! "${sha256sums_x86_64[0]}" =~ ^[[:xdigit:]]{64}$ ||
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

download_and_verify "${source[0]%%::*}" "$license_url" "${sha256sums[0]}"
download_and_verify "$x64_name" "$x64_url" "${sha256sums_x86_64[0]}"
download_and_verify "$arm64_name" "$arm64_url" "${sha256sums_aarch64[0]}"

x64_file_type="$(file -b "$workdir/$x64_name")"
arm64_file_type="$(file -b "$workdir/$arm64_name")"
grep -Eq 'ELF 64-bit.*x86-64' <<<"$x64_file_type" ||
	{ echo "x86_64 artifact is not an x86-64 ELF: $x64_file_type" >&2; exit 1; }
grep -Eq 'ELF 64-bit.*ARM aarch64' <<<"$arm64_file_type" ||
	{ echo "aarch64 artifact is not an ARM ELF: $arm64_file_type" >&2; exit 1; }

makepkg --verifysource --force --nocolor
namcap PKGBUILD

if [[ "${RUN_SMOKE_TEST:-1}" != 0 ]]; then
	smoke_allowed=true
	if [[ "$host_carch" == x86_64 ]] && ! grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
		smoke_allowed=false
		echo "Skipping x86_64 execution smoke test because the host has no AVX2 flag."
	fi

	if [[ "$smoke_allowed" == true ]]; then
		case "$host_carch" in
			x86_64)
				smoke_binary="$workdir/$x64_name"
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
fi

if [[ "$build_package" == true ]]; then
	built_package="$(makepkg --packagelist --nobuild --nodeps --noconfirm --nocolor | head -n 1)"
	makepkg --cleanbuild --force --nodeps --noconfirm --nocolor
	namcap "$built_package"

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
