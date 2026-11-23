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
  --binary-images iso \
  --bootloader grub2 \
  --memtest none \
  --compression xz \
  --apt-recommends true \
  --security true \
  --iso-application "${ISO_NAME}" \
  --iso-volume "${ISO_NAME}-${UBUNTU_CODENAME}"

# Copy custom includes and hooks (live-build 3.0 reads hooks from config/hooks/*.hook.chroot)
mkdir -p config/includes.chroot config/hooks config/package-lists config/archives
cp -r "${REPO_ROOT}/config/includes.chroot/." config/includes.chroot/
cp -r "${REPO_ROOT}/config/hooks/live/." config/hooks/

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
  cat <<'EOF' > config/hooks/00-upgrade-farm.hook.chroot
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
Pin-Priority: 1002
INNER

apt-get update
apt-get dist-upgrade -y --allow-downgrades
EOF

  cat <<'EOF' > config/hooks/99-cleanup-farm-repo.hook.chroot
#!/bin/bash
set -euo pipefail
echo "=== [99-cleanup-farm-repo] Removing temporary local APT repo from image ==="
rm -rf /opt/decanonicaled-repo /etc/apt/sources.list.d/decanonicaled-local* /etc/apt/preferences.d/decanonicaled-local*
apt-get clean
EOF
elif [[ -n "${APT_SHARD_URLS}" ]]; then
  echo "=== No local FARM_DEBS_DIR; upgrading chroot from sharded GitHub Releases ==="
  cat <<'EOF' > config/hooks/00-upgrade-farm.hook.chroot
#!/bin/bash
set -euo pipefail
echo "=== [00-upgrade-farm] Upgrading from sharded GitHub Releases APT repo ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get dist-upgrade -y --allow-downgrades
apt-get clean
EOF
fi

chmod +x config/hooks/*.hook.chroot

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
syslinux-utils
EOF

# Flavor-specific packages
case "${FLAVOR}" in
  gnome-minimal)
    cat <<'EOF' >> config/package-lists/decanonicaled.list.chroot
ubuntu-desktop-minimal
gdm3
gnome-shell
ubuntu-session
gnome-control-center
pipewire-pulse
wireplumber
xwayland
xdg-desktop-portal-gnome
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

# Run live-build to assemble chroot, casper/, and binary/ tree
lb build

# Rebuild the ISO using grub-mkrescue so both BIOS and UEFI boot work reliably
# (Ubuntu 24.04's live-build 3.0 calls grub-mkimage without -p and omits UEFI).
VMLINUZ_PATH="$(find "${BUILD_DIR}/binary/casper" -maxdepth 1 -name 'vmlinuz-*' | head -n 1)"
INITRD_PATH="$(find "${BUILD_DIR}/binary/casper" -maxdepth 1 -name 'initrd.img-*' | head -n 1)"
if [[ -z "${VMLINUZ_PATH}" ]] || [[ -z "${INITRD_PATH}" ]]; then
  echo "ERROR: Missing kernel or initrd in ${BUILD_DIR}/binary/casper." >&2
  exit 1
fi

VMLINUZ_NAME="$(basename "${VMLINUZ_PATH}")"
INITRD_NAME="$(basename "${INITRD_PATH}")"

rm -f "${BUILD_DIR}"/*.iso
rm -rf "${BUILD_DIR}/binary/boot/grub"
mkdir -p "${BUILD_DIR}/binary/boot/grub"

cat <<EOF > "${BUILD_DIR}/binary/boot/grub/grub.cfg"
set timeout=5
set default=0

menuentry "Try or Install Decanonicaled Ubuntu (${UBUNTU_CODENAME})" {
    linux /casper/${VMLINUZ_NAME} boot=casper quiet splash ---
    initrd /casper/${INITRD_NAME}
}

menuentry "Decanonicaled Ubuntu (${UBUNTU_CODENAME}, Safe Graphics / Verbose)" {
    linux /casper/${VMLINUZ_NAME} boot=casper nomodeset console=tty0 console=ttyS0,115200 ---
    initrd /casper/${INITRD_NAME}
}
EOF

TARGET_ISO="${BUILD_DIR}/${ISO_NAME}-${UBUNTU_CODENAME}-${FLAVOR}-amd64.iso"
grub-mkrescue -o "${TARGET_ISO}" "${BUILD_DIR}/binary" -- -volid "${ISO_NAME}-${UBUNTU_CODENAME}"

echo "=== ISO build complete: ${TARGET_ISO} ==="
