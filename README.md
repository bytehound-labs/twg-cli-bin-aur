# twg-cli-bin AUR package

`twg-cli-bin` is an unofficial Arch Linux package for the prebuilt Atlassian
Teamwork Graph CLI (`twg`). It installs the vendor-supplied binary at
`/usr/bin/twg` for `x86_64` and `aarch64`.

## Installation

Install from the Arch User Repository with an AUR helper:

```bash
paru -S twg-cli-bin
```

Or build it manually:

```bash
git clone https://aur.archlinux.org/twg-cli-bin.git
cd twg-cli-bin
makepkg -si
```

The package installs the binary only. Authentication, agent skill installation,
and per-user configuration remain explicit setup actions:

```bash
twg setup
twg doctor
```

Use pacman or an AUR helper to upgrade this package. Do not use `twg update` or
the upstream installer to replace the package-managed `/usr/bin/twg`.

## Compatibility

The package supports:

- `x86_64`
- `aarch64`

The upstream Linux `x86_64` artifact uses AVX2 instructions. Older x86_64
processors without AVX2 may exit with `Illegal instruction`; the package
preserves the upstream binary and does not claim compatibility with those
processors.

An unrelated AUR package named `twg` provides a Twitter client and also owns
`/usr/bin/twg`. Remove that package before installing `twg-cli-bin`.

## Release source and licensing

Stable versions, architecture-specific assets, and SHA-256 checksums come from
the [Atlassian stable manifest](https://teamwork-graph.atlassian.com/cli/manifest.json).
Setup and usage documentation is available in the
[Atlassian TWG CLI installation guide](https://developer.atlassian.com/cloud/twg-cli/getting-started/installation/).

The upstream project is distributed under the
[Apache License 2.0](https://github.com/atlassian/twg-cli/blob/main/LICENSE).
This package is not maintained, endorsed, or sponsored by Atlassian.

## Package automation

The [GitHub mirror](https://github.com/bytehound-labs/twg-cli-bin-aur) polls the
stable manifest, validates the downloaded artifacts, updates the package
metadata, and publishes only `PKGBUILD` and `.SRCINFO` to the
[AUR package repository](https://aur.archlinux.org/packages/twg-cli-bin).
