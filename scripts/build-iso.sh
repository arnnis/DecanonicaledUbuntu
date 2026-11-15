#!/bin/bash
set -euo pipefail

UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
FLAVOR="${FLAVOR:-gnome-minimal}"
ISO_NAME="${ISO_NAME:-decanonicaled-ubuntu}"
FARM_DEBS_DIR="${FARM_DEBS_DIR:-}"
APT_SHARD_URLS="${APT_SHARD_URLS:-}"
APT_GPG_KEY_FILE="${APT_GPG_KEY_FILE:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"

echo "=== Building ${ISO_NAME} (${UBUNTU_CODENAME} / ${FLAVOR}) ==="

# Ensure debootstrap has a script for newer Ubuntu codenames (e.g. resolute on 24.04 host)
if [[ ! -e "/usr/share/debootstrap/scripts/${UBUNTU_CODENAME}" ]] && [[ -e "/usr/share/debootstrap/scripts/gutsy" ]]; then
  echo "Symlinking /usr/share/debootstrap/scripts/${UBUNTU_CODENAME} -> gutsy"
  ln -s gutsy "/usr/share/debootstrap/scripts/${UBUNTU_CODENAME}"
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Configure live-build for Ubuntu
lb config \
  --mode ubuntu \
  --distribution "${UBUNTU_CODENAME}" \
  --architectures amd64 \
  --archive-areas "main restricted universe multiverse" \
  --mirror-bootstrap "http://archive.ubuntu.com/ubuntu/" \
  --mirror-chroot "http://archive.ubuntu.com/ubuntu/" \
  --mirror-binary "http://archive.ubuntu.com/ubuntu/" \
  --linux-flavours generic \
  --binary-images iso-hybrid \
  --bootloader grub2 \
  --memtest none \
  --apt-recommends true \
  --security true \
  --iso-application "${ISO_NAME}" \
  --iso-volume "${ISO_NAME}-${UBUNTU_CODENAME}"

# Copy custom includes and hooks
mkdir -p config/includes.chroot config/hooks/live config/package-lists config/archives
cp -r "${REPO_ROOT}/config/includes.chroot/." config/includes.chroot/
cp -r "${REPO_ROOT}/config/hooks/live/." config/hooks/live/

# Bake persistent sharded GitHub Releases APT repo into the installed system for future updates
if [[ -n "${APT_SHARD_URLS}" ]] && [[ -n "${APT_GPG_KEY_FILE}" ]] && [[ -f "${APT_GPG_KEY_FILE}" ]]; then
  echo "=== Baking persistent sharded APT repositories into ISO ==="
  install -d -m 0755 config/includes.chroot/etc/apt/keyrings
  install -d -m 0755 config/includes.chroot/etc/apt/sources.list.d
  install -d -m 0755 config/includes.chroot/etc/apt/preferences.d

  cp "${APT_GPG_KEY_FILE}" config/includes.chroot/etc/apt/keyrings/decanonicaled.gpg
  chmod 0644 config/includes.chroot/etc/apt/keyrings/decanonicaled.gpg

  : > config/includes.chroot/etc/apt/sources.list.d/decanonicaled.list
  for shard_url in ${APT_SHARD_URLS}; do
    echo "deb [signed-by=/etc/apt/keyrings/decanonicaled.gpg] ${shard_url} ./" >> config/includes.chroot/etc/apt/sources.list.d/decanonicaled.list
  done

  cat <<'EOF' > config/includes.chroot/etc/apt/preferences.d/decanonicaled.pref
Package: *
Pin: release o=DecanonicaledUbuntu
Pin-Priority: 1001
EOF
fi

# If farm-compiled .deb packages are provided, expose them as a high-priority local APT repo
if [[ -n "${FARM_DEBS_DIR}" ]] && [[ -d "${FARM_DEBS_DIR}" ]] && compgen -G "${FARM_DEBS_DIR}/*.deb" >/dev/null; then
  DEB_COUNT=$(find "${FARM_DEBS_DIR}" -maxdepth 1 -name '*.deb' | wc -l)
  echo "=== Indexing ${DEB_COUNT} farm-compiled .deb packages into local APT repo ==="

  LOCAL_REPO_CHROOT="config/includes.chroot/opt/decanonicaled-repo"
  mkdir -p "${LOCAL_REPO_CHROOT}"
  cp "${FARM_DEBS_DIR}"/*.deb "${LOCAL_REPO_CHROOT}/"

  pushd "${LOCAL_REPO_CHROOT}" >/dev/null
  apt-ftparchive packages . > Packages
  gzip -k -f Packages
  apt-ftparchive release . > Release
  popd >/dev/null

  # Upgrade installed base packages to farm-compiled versions, then remove repo from final squashfs
  cat <<'EOF' > config/hooks/live/00-upgrade-farm.hook.chroot
#!/bin/bash
set -euo pipefail
echo "=== [00-upgrade-farm] Configuring & upgrading from farm-compiled APT repo ==="
export DEBIAN_FRONTEND=noninteractive

cat <<'INNER' > /etc/apt/sources.list.d/decanonicaled-local.list
deb [trusted=yes] file:/opt/decanonicaled-repo ./
INNER

cat <<'INNER' > /etc/apt/preferences.d/decanonicaled-local.pref
Package: *
Pin: origin ""
Pin-Priority: 1001
INNER

apt-get update
apt-get dist-upgrade -y --allow-downgrades
EOF

  cat <<'EOF' > config/hooks/live/99-cleanup-farm-repo.hook.chroot
#!/bin/bash
set -euo pipefail
echo "=== [99-cleanup-farm-repo] Removing temporary local APT repo from image ==="
rm -rf /opt/decanonicaled-repo /etc/apt/sources.list.d/decanonicaled-local* /etc/apt/preferences.d/decanonicaled-local*
apt-get clean
EOF
fi

chmod +x config/hooks/live/*.hook.chroot

# Base packages needed across all flavors (excluding snapd & telemetry)
cat <<'EOF' > config/package-lists/decanonicaled.list.chroot
ubuntu-minimal
ubuntu-standard
casper
network-manager
sudo
curl
ca-certificates
gnupg
vim-tiny
less
EOF

# Flavor-specific packages
case "${FLAVOR}" in
  gnome-minimal)
    cat <<'EOF' >> config/package-lists/decanonicaled.list.chroot
ubuntu-desktop-minimal
gnome-terminal
nautilus
gnome-text-editor
calamares
ubuntu-drivers-common
dkms
EOF
    ;;
  xfce)
    cat <<'EOF' >> config/package-lists/decanonicaled.list.chroot
xubuntu-core
xfce4-terminal
thunar
calamares
ubuntu-drivers-common
dkms
EOF
    ;;
  server)
    cat <<'EOF' >> config/package-lists/decanonicaled.list.chroot
openssh-server
htop
tmux
EOF
    ;;
  *)
    echo "Unknown flavor: ${FLAVOR}" >&2
    exit 1
    ;;
esac

# Run live-build
lb build

# Normalize output ISO filename
GENERATED_ISO="$(find "${BUILD_DIR}" -maxdepth 1 -name '*.iso' | head -n 1)"
if [[ -z "${GENERATED_ISO}" ]]; then
  echo "ERROR: No ISO file generated by live-build." >&2
  exit 1
fi

TARGET_ISO="${BUILD_DIR}/${ISO_NAME}-${UBUNTU_CODENAME}-${FLAVOR}-amd64.iso"
if [[ "${GENERATED_ISO}" != "${TARGET_ISO}" ]]; then
  mv "${GENERATED_ISO}" "${TARGET_ISO}"
fi

echo "=== ISO build complete: ${TARGET_ISO} ==="
