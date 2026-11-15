# DecanonicaledUbuntu

A `buildd`-style **GitHub Actions Build Farm** + **Sharded GitHub Releases APT Repository** that compiles Ubuntu 26.04 LTS (`resolute`) source packages into `.deb` binaries, bakes them into a clean, snap-free, telemetry-free bootable Ubuntu ISO (with `calamares` GUI installer), and keeps installed machines updated daily via `apt upgrade`.

## Architecture

1. **`plan-farm`** ([`scripts/resolve-sources.sh`](scripts/resolve-sources.sh))
   - Runs inside an `ubuntu:<codename>` container so dependency resolution matches the target Ubuntu release.
   - Resolves either `core` ([`config/source-packages/core.txt`](config/source-packages/core.txt)) or `full` (entire dependency tree of the flavor), splitting heavy builds (`linux`, `gcc-*`, `llvm-*`, `mesa`, `webkit2gtk`, etc.) into solo runners and distributing lighter packages across up to **20 parallel GitHub Actions workers**.
2. **`build-farm`** ([`scripts/build-package.sh`](scripts/build-package.sh))
   - Each parallel runner compiles inside an isolated `ubuntu:<codename>` container, fetches upstream Ubuntu source (`apt-get source`), installs `Build-Depends`, bumps the version with `+decanonicaled1`, compiles `.deb`s with `dpkg-buildpackage` + `ccache`, and skips `-dev`/`-doc`/`-dbg`/`-dbgsym` packages.
3. **Sharded GitHub Releases APT Repository** ([`scripts/publish-release-shards.sh`](scripts/publish-release-shards.sh))
   - Automatically chunks compiled `.deb`s into numbered GitHub Releases (`apt-pool-<codename>-01`, `-02`, ...) with **max 800 `.deb`s per release** (avoiding GitHub's 1,000-asset release cap, 100 MB git file limit, and 1 GB GitHub Pages limit).
   - Sanitizes filenames (`+`/`~` → `.`), generates `Packages.gz` & `Release`, signs with GPG (`Release.gpg` + `InRelease`), and only re-uploads changed shards on updates.
4. **ISO Assembly** ([`scripts/build-iso.sh`](scripts/build-iso.sh))
   - Installs farm-compiled `.deb`s into the `live-build` chroot, strips Canonical bloat (snaps, telemetry, Ubuntu Pro, pre-installed games), includes `calamares` for desktop installs, and bakes `/etc/apt/sources.list.d/decanonicaled.list` (all shard URLs), `/etc/apt/preferences.d/decanonicaled.pref`, and `/etc/apt/keyrings/decanonicaled.gpg` into the ISO.
5. **Daily Incremental Updates** ([`.github/workflows/update-apt-repo.yml`](.github/workflows/update-apt-repo.yml))
   - Runs every day at `02:00 UTC` (or manually), compares upstream `-security` / `-updates` versions against all existing shard `Packages.gz` files, and **only recompiles packages that actually changed**.

## One-Time Setup on GitHub

1. **Create a persistent GPG signing key** (recommended so installed systems trust future daily updates):
   ```bash
   gpg --batch --passphrase "" --quick-generate-key "DecanonicaledUbuntu APT <apt@example.com>" rsa4096 sign 5y
   gpg --armor --export-secret-keys "DecanonicaledUbuntu APT" | base64 -w0
   ```
   Add the base64 output as a repository secret named **`APT_GPG_PRIVATE_KEY`** (in **Settings → Secrets and variables → Actions**). *(If omitted, an ephemeral key is generated per run.)*
2. **Push to GitHub and run** **Actions → Build Decanonicaled Ubuntu ISO (Build Farm) → Run workflow**.
   *(No GitHub Pages configuration or external server is required.)*

## What Gets Removed
- **Snaps**: Purges `snapd`, `gnome-software-plugin-snap`, `libsnapd-glib*`, deletes `/snap` and `/var/lib/snapd`, and pins `snapd` at `-10` ([`nosnap.pref`](config/includes.chroot/etc/apt/preferences.d/nosnap.pref)).
- **Browser**: Installs native `.deb` Firefox from Mozilla's official APT repo (`packages.mozilla.org`) on desktop flavors.
- **Telemetry & Pro**: Purges `ubuntu-report`, `popularity-contest`, `whoopsie`, `apport*`, `kerneloops`, `ubuntu-advantage-tools` / `ubuntu-pro-client`, disables `motd-news`, and sets GNOME privacy dconf defaults.
- **Bloat**: Removes `gnome-tour`, `ubuntu-web-launchers`, pre-installed games, `rhythmbox`, `totem`, and `thunderbird`.
