#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: publish-aur-tree.sh [file ...]

Replace the AUR repository tree with the supplied package payload and push it
to master. If no files are supplied, PKGBUILD, .SRCINFO, and the baseline
patcher are published.
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

if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then
	usage
	exit 0
fi

for command in git install mktemp rm sed; do
	require_command "$command"
done

aur_remote="${AUR_REMOTE:-ssh://aur@aur.archlinux.org/twg-cli-bin.git}"
pkgname="$(sed -n 's/^pkgname=//p' PKGBUILD | head -n 1 | tr -d "'\"")"
pkgver="$(sed -n 's/^pkgver=//p' PKGBUILD | head -n 1)"
pkgrel="$(sed -n 's/^pkgrel=//p' PKGBUILD | head -n 1)"
commit_message="${AUR_COMMIT_MESSAGE:-upgpkg: ${pkgname} ${pkgver}-${pkgrel}}"

if (($# > 0)); then
	aur_files=("$@")
else
	aur_files=(PKGBUILD .SRCINFO twg-baseline-patcher.py)
fi

tmpdir="$(mktemp -d)"
cleanup() {
	rm -rf "$tmpdir"
}
trap cleanup EXIT

git clone --quiet "$aur_remote" "$tmpdir"
git -C "$tmpdir" config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git -C "$tmpdir" config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

while IFS= read -r -d '' tracked_path; do
	rm -rf -- "$tmpdir/$tracked_path"
done < <(git -C "$tmpdir" ls-files -z)

for aur_file in "${aur_files[@]}"; do
	if [[ ! -f "$repo_root/$aur_file" ]]; then
		echo "AUR payload file does not exist: $aur_file" >&2
		exit 1
	fi
	install -Dm644 "$repo_root/$aur_file" "$tmpdir/$aur_file"
done

git -C "$tmpdir" add -A
if git -C "$tmpdir" diff --cached --quiet; then
	echo "AUR tree is already up to date."
	exit 0
fi

git -C "$tmpdir" commit -m "$commit_message"
git -C "$tmpdir" push origin HEAD:master
