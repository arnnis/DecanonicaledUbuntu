#!/bin/bash
set -euo pipefail

UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
PACKAGES="${PACKAGES:-}"
OUT_DIR="${OUT_DIR:-$(pwd)/out-debs}"
FAIL_ON_PKG_ERROR="${FAIL_ON_PKG_ERROR:-false}"
CCACHE_DIR="${CCACHE_DIR:-${HOME}/.ccache}"

if [[ -z "${PACKAGES}" ]]; then
  echo "No packages specified in PACKAGES."
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${OUT_DIR}" "${CCACHE_DIR}"

# Run compilation inside a clean container matching UBUNTU_CODENAME (e.g. ubuntu:resolute)
# so Build-Depends, glibc, and compilers match the target Ubuntu release.
if command -v docker >/dev/null 2>&1 && [[ -z "${IN_TARGET_CONTAINER:-}" ]]; then
  exec docker run --rm \
    -e IN_TARGET_CONTAINER=1 \
    -e UBUNTU_CODENAME="${UBUNTU_CODENAME}" \
    -e PACKAGES="${PACKAGES}" \
    -e OUT_DIR="/out-debs" \
    -e FAIL_ON_PKG_ERROR="${FAIL_ON_PKG_ERROR}" \
    -e CCACHE_DIR="/ccache" \
    -v "${REPO_ROOT}:/workspace:ro" \
    -v "${OUT_DIR}:/out-debs" \
    -v "${CCACHE_DIR}:/ccache" \
    -w /workspace \
    "ubuntu:${UBUNTU_CODENAME}" \
    bash /workspace/scripts/build-package.sh
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  dpkg-dev \
  devscripts \
  debhelper \
  fakeroot \
  ccache \
  build-essential \
  ca-certificates

# Enable deb-src for target Ubuntu codename
cat <<EOF > /etc/apt/sources.list.d/decanonicaled-src.list
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

apt-get update -qq

export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
export DEBEMAIL="farm@decanonicaled.local"
export DEBFULLNAME="DecanonicaledUbuntu Build Farm"
export PATH="/usr/lib/ccache:${PATH}"

WORK_ROOT="/tmp/pkg-build"
rm -rf "${WORK_ROOT}"
mkdir -p "${WORK_ROOT}"

for pkg in ${PACKAGES}; do
  echo "============================================================"
  echo ">>> [buildd-worker:${UBUNTU_CODENAME}] Building source package: ${pkg}"
  echo "============================================================"

  PKG_DIR="${WORK_ROOT}/${pkg}"
  mkdir -p "${PKG_DIR}"
  pushd "${PKG_DIR}" >/dev/null

  if ! apt-get source "${pkg}"; then
    echo "ERROR: Failed to fetch source for ${pkg}" | tee -a "${OUT_DIR}/failed.txt"
    popd >/dev/null
    rm -rf "${PKG_DIR}"
    [[ "${FAIL_ON_PKG_ERROR}" == "true" ]] && exit 1
    continue
  fi

  SRC_SUBDIR="$(find . -maxdepth 1 -mindepth 1 -type d | head -n 1)"
  if [[ -z "${SRC_SUBDIR}" ]]; then
    echo "ERROR: No extracted source directory for ${pkg}" | tee -a "${OUT_DIR}/failed.txt"
    popd >/dev/null
    rm -rf "${PKG_DIR}"
    [[ "${FAIL_ON_PKG_ERROR}" == "true" ]] && exit 1
    continue
  fi

  if ! apt-get build-dep -y "${pkg}"; then
    echo "ERROR: Failed to install build-deps for ${pkg}" | tee -a "${OUT_DIR}/failed.txt"
    popd >/dev/null
    rm -rf "${PKG_DIR}"
    [[ "${FAIL_ON_PKG_ERROR}" == "true" ]] && exit 1
    continue
  fi

  pushd "${SRC_SUBDIR}" >/dev/null
  dch --local "+decanonicaled" --distribution "${UBUNTU_CODENAME}" \
    "Compiled from source by DecanonicaledUbuntu build farm" || true

  if dpkg-buildpackage -b -uc -us -j"$(nproc)"; then
    popd >/dev/null
    find "${PKG_DIR}" -maxdepth 1 -name '*.deb' \
      ! -name '*-dbgsym_*.deb' \
      ! -name '*-dbg_*.deb' \
      ! -name '*-dev_*.deb' \
      ! -name '*-doc_*.deb' \
      -exec cp -v {} "${OUT_DIR}/" \;
  else
    echo "ERROR: dpkg-buildpackage failed for ${pkg}" | tee -a "${OUT_DIR}/failed.txt"
    popd >/dev/null
    popd >/dev/null
    rm -rf "${PKG_DIR}"
    [[ "${FAIL_ON_PKG_ERROR}" == "true" ]] && exit 1
    continue
  fi

  popd >/dev/null
  rm -rf "${PKG_DIR}"
  apt-get clean
done

echo "=== Build worker finished. Compiled .deb count: $(find "${OUT_DIR}" -name '*.deb' | wc -l) ==="
