# DecanonicaledUbuntu

> **⚠️ EXPERIMENTAL — USE AT YOUR OWN RISK**
>
> **Disclaimer:** This project is experimental. Bootable ISOs and self-compiled `.deb` packages are provided **as-is, without warranty of any kind**. Always verify checksums (`SHA256SUMS`) and test in a virtual machine (e.g., QEMU) before installing on bare-metal hardware.
>
> *This project is an independent community build pipeline and is not affiliated with, endorsed by, or supported by Canonical Ltd. or Ubuntu.*

A `buildd`-style **GitHub Actions Build Farm** + **Sharded GitHub Releases APT Repository** that compiles Ubuntu 26.04 LTS (`resolute`) source packages into `.deb` binaries, bakes them into a clean, snap-free, telemetry-free bootable Ubuntu ISO (with `calamares` GUI installer), and keeps installed machines updated daily via `apt upgrade`.

## Downloads & Builds

- **GitHub Actions (Workflows & ISO Artifacts):** https://github.com/arnnis/DecanonicaledUbuntu/actions
- **Latest `full` Scope ISO Build (`resolute` / `gnome-minimal`):** https://github.com/arnnis/DecanonicaledUbuntu/actions/runs/44147092742
  *(Download the `decanonicaled-ubuntu-resolute-gnome-minimal-full` artifact `.zip` and extract the `.iso` + `SHA256SUMS`. Note: GitHub Actions artifacts expire after 14 days; trigger a new workflow run or push a `v*` tag for permanent GitHub Releases.)*
- **GitHub Releases (Sharded APT Pool & Tagged ISO Releases):** https://github.com/arnnis/DecanonicaledUbuntu/releases

## Architecture

1. **`plan-farm`** ([`scripts/resolve-sources.sh`](scripts/resolve-sources.sh))
   - Runs inside an `ubuntu:<codename>` container so dependency resolution matches the target Ubuntu release.
   - Resolves either `core` ([`config/source-packages/core.txt`](config/source-packages/core.txt)) or `full` (entire dependency tree of the flavor via `apt-get install --simulate --install-recommends`), splitting heavy builds (`linux`, `gcc-*`, `llvm-*`, `mesa`, `webkit2gtk`, etc.) into solo runners and distributing lighter packages across up to **60 farm workers** (20 concurrent).
2. **`build-farm`** ([`scripts/build-package.sh`](scripts/build-package.sh))
   - Each parallel runner compiles inside an isolated `ubuntu:<codename>` container, fetches upstream Ubuntu source (`apt-get source`), installs `Build-Depends`, bumps the version with `+decanonicaled1`, compiles `.deb`s with `dpkg-buildpackage` + `ccache`, and skips `-dev`/`-doc`/`-dbg`/`-dbgsym` packages.
3. **Sharded GitHub Releases APT Repository** ([`scripts/publish-release-shards.sh`](scripts/publish-release-shards.sh))
   - Automatically chunks compiled `.deb`s into numbered GitHub Releases (`apt-pool-<codename>-01`, `-02`, ...) with **max 800 `.deb`s per release** (avoiding GitHub's 1,000-asset release cap, 100 MB git file limit, and 1 GB GitHub Pages limit).
   - Sanitizes filenames (`+`/`~`/`:` → `.`), generates `Packages.gz` & `Release`, signs with GPG (`Release.gpg` + `InRelease`), and only re-uploads changed shards on updates.
4. **ISO Assembly** ([`scripts/build-iso.sh`](scripts/build-iso.sh))
   - Installs farm-compiled `.deb`s into the `live-build` chroot, strips Canonical bloat (snaps, telemetry, Ubuntu Pro, pre-installed games), includes `calamares` for desktop installs, bakes `/etc/apt/sources.list.d/decanonicaled.list` (all shard URLs), `/etc/apt/preferences.d/decanonicaled.pref`, and `/etc/apt/keyrings/decanonicaled.gpg`, and packs a hybrid BIOS + UEFI ISO using `grub-mkrescue`.
5. **Daily Incremental Updates** ([`.github/workflows/update-apt-repo.yml`](.github/workflows/update-apt-repo.yml))
   - Runs every day at `02:00 UTC` (or manually), compares upstream `-security` / `-updates` versions against all existing shard `Packages.gz` files, and **only recompiles packages that actually changed**.

## One-Time Setup on GitHub

1. **Create a persistent GPG signing key** (recommended so installed systems trust future daily updates):
   ```bash
   gpg --batch --passphrase "" --quick-generate-key "DecanonicaledUbuntu APT <apt@example.com>" rsa4096 sign 5y
   gpg --armor --export-secret-keys "DecanonicaledUbuntu APT" | base64 -w0
   ```
   Add the base64 output as a repository secret named **`APT_GPG_PRIVATE_KEY`** (in **Settings → Secrets and variables → Actions**). *(If omitted, an ephemeral key is generated per run.)*
2. **Run** **Actions → Build Decanonicaled Ubuntu ISO (Build Farm) → Run workflow**.

## What Gets Removed
- **Snaps**: Purges `snapd`, `gnome-software-plugin-snap`, `libsnapd-glib*`, deletes `/snap` and `/var/lib/snapd`, and pins `snapd` at `-10` ([`nosnap.pref`](config/includes.chroot/etc/apt/preferences.d/nosnap.pref)).
- **Browser**: Installs native `.deb` Firefox from Mozilla's official APT repo (`packages.mozilla.org`) on desktop flavors.
- **Telemetry & Pro**: Purges `ubuntu-report`, `popularity-contest`, `whoopsie`, `apport*`, `kerneloops`, `ubuntu-advantage-tools` / `ubuntu-pro-client`, disables `motd-news`, and sets GNOME privacy dconf defaults.
- **Bloat**: Removes `gnome-tour`, `ubuntu-web-launchers`, pre-installed games, `rhythmbox`, `totem`, and `thunderbird`.

## License

Licensed under the [MIT License](LICENSE).
