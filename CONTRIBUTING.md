# Maintaining twg-cli-bin

This repository is the automation mirror for the `twg-cli-bin` AUR package.
The AUR repository contains only `PKGBUILD` and `.SRCINFO`; workflows, scripts,
and maintenance documentation stay in this GitHub repository.

## Requirements

Package validation runs in an Arch Linux `base-devel` environment and requires
`curl`, `file`, `git`, `jq`, `namcap`, `openssh`, and the standard `makepkg`
toolchain.

## Local workflow

Preview the stable-manifest update without changing files:

```bash
./scripts/update-upstream-release.sh --dry-run
```

Apply the stable-manifest update and regenerate `.SRCINFO`:

```bash
./scripts/update-upstream-release.sh
```

Validate source URLs, checksums, ELF architectures, package metadata, and
`namcap` output:

```bash
./scripts/validate-package.sh
```

Build and inspect a package locally:

```bash
./scripts/validate-package.sh --build
```

Publish the current package payload to an existing AUR repository:

```bash
./scripts/publish-aur-tree.sh
```

The publisher uses `GIT_SSH_COMMAND` when it is supplied by the workflow or
caller. It never discovers host keys at runtime; `.github/aur-known_hosts`
provides the pinned AUR host keys used by CI.

## Release automation

`.github/workflows/update-aur-package.yml` polls the documented Atlassian stable
manifest every six hours. A changed version or checksum causes the workflow to:

1. Update `PKGBUILD` and `.SRCINFO`.
2. Validate both Linux artifacts and package metadata in an Arch container.
3. Commit the generated files to the GitHub mirror.
4. Publish the two AUR payload files over a strict, key-pinned SSH connection.

Manual dispatch supports a full package build and an idempotent publish of the
current package state. An unchanged scheduled run creates no commits.

## GitHub and AUR setup

Create the mirror from the local repository:

```bash
gh repo create bytehound-labs/twg-cli-bin-aur \
  --public \
  --source=. \
  --remote=origin \
  --push
```

Load the AUR private key into the GitHub Actions secret without printing it:

```bash
gh secret set AUR_SSH_PRIVATE_KEY \
  --repo bytehound-labs/twg-cli-bin-aur \
  < ~/.ssh/id_rsa
```

The matching public key must be registered with the AUR account that owns
`twg-cli-bin`. The workflow uses the repository-scoped `GITHUB_TOKEN` for
mirror commits and the `AUR_SSH_PRIVATE_KEY` secret only for AUR publishing.

The AUR package must be created at
<https://aur.archlinux.org/packages/twg-cli-bin> before the first publisher
run can clone it. After the package repository exists, trigger the workflow
with `full_build` and `publish_current` enabled.

## Packaging decisions

- Stable release discovery uses the Atlassian manifest rather than GitHub
  releases because the public GitHub repository has no release/tag feed.
- Vendor binaries are installed unchanged and are not stripped or debug-split.
- The package does not run `twg setup`, authenticate a user, install skills, or
  invoke the upstream self-updater.
- A same-version asset, checksum, or upstream license change increments
  `pkgrel`; a new upstream version resets it to `1`.
- A source checksum mismatch, unexpected CDN URL, malformed version, channel
  change, or release downgrade stops the updater.
