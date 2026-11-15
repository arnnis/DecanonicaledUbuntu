#!/bin/bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(pwd)/gh-pages-repo}"
NEW_DEBS_DIR="${NEW_DEBS_DIR:-$(pwd)/farm-debs}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
APT_GPG_PRIVATE_KEY="${APT_GPG_PRIVATE_KEY:-}"
APT_GPG_PASSPHRASE="${APT_GPG_PASSPHRASE:-}"

POOL_DIR="${REPO_DIR}/pool/main"
DIST_DIR="${REPO_DIR}/dists/${UBUNTU_CODENAME}"
BIN_DIR="${DIST_DIR}/main/binary-amd64"

mkdir -p "${POOL_DIR}" "${BIN_DIR}"

# Copy newly compiled .debs into pool
if [[ -d "${NEW_DEBS_DIR}" ]] && compgen -G "${NEW_DEBS_DIR}/*.deb" >/dev/null; then
  cp -f "${NEW_DEBS_DIR}"/*.deb "${POOL_DIR}/"
fi

# Prune superseded older versions of the same package+arch to keep GitHub Pages compact
python3 - "${POOL_DIR}" <<'PY'
import os
import subprocess
import sys
from collections import defaultdict

pool_dir = sys.argv[1]
groups = defaultdict(list)

for fname in os.listdir(pool_dir):
    if not fname.endswith(".deb"):
        continue
    fpath = os.path.join(pool_dir, fname)
    try:
        pkg = subprocess.check_output(["dpkg-deb", "-f", fpath, "Package"], text=True).strip()
        ver = subprocess.check_output(["dpkg-deb", "-f", fpath, "Version"], text=True).strip()
        arch = subprocess.check_output(["dpkg-deb", "-f", fpath, "Architecture"], text=True).strip()
        groups[(pkg, arch)].append((ver, fpath))
    except subprocess.CalledProcessError:
        continue

removed = 0
for (pkg, arch), items in groups.items():
    if len(items) <= 1:
        continue
    # Find highest version using dpkg --compare-versions
    best_ver, best_path = items[0]
    for ver, fpath in items[1:]:
        rc = subprocess.call(["dpkg", "--compare-versions", ver, "gt", best_ver])
        if rc == 0:
            best_ver, best_path = ver, fpath
    for ver, fpath in items:
        if fpath != best_path:
            os.remove(fpath)
            removed += 1

print(f"Pruned {removed} superseded .deb files from pool.")
PY

# Generate Packages and Packages.gz
pushd "${REPO_DIR}" >/dev/null
dpkg-scanpackages --multiversion "pool/main" > "${BIN_DIR}/Packages"
gzip -k -f -9 "${BIN_DIR}/Packages"

# Generate Release
apt-ftparchive \
  -o "APT::FTPArchive::Release::Origin=DecanonicaledUbuntu" \
  -o "APT::FTPArchive::Release::Label=DecanonicaledUbuntu" \
  -o "APT::FTPArchive::Release::Suite=${UBUNTU_CODENAME}" \
  -o "APT::FTPArchive::Release::Codename=${UBUNTU_CODENAME}" \
  -o "APT::FTPArchive::Release::Architectures=amd64" \
  -o "APT::FTPArchive::Release::Components=main" \
  -o "APT::FTPArchive::Release::Description=DecanonicaledUbuntu self-compiled APT repository" \
  release "${DIST_DIR}" > "${DIST_DIR}/Release"

# Setup GPG keyring for signing
GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
chmod 700 "${GNUPGHOME}"

if [[ -n "${APT_GPG_PRIVATE_KEY}" ]]; then
  echo "Importing APT_GPG_PRIVATE_KEY from secret..."
  if echo "${APT_GPG_PRIVATE_KEY}" | grep -q "BEGIN PGP PRIVATE KEY BLOCK"; then
    echo "${APT_GPG_PRIVATE_KEY}" | gpg --batch --import
  else
    echo "${APT_GPG_PRIVATE_KEY}" | base64 -d | gpg --batch --import
  fi
else
  echo "WARNING: APT_GPG_PRIVATE_KEY secret not set; generating ephemeral GPG key for this run."
  echo "         For persistent apt-upgrade trust across releases, add APT_GPG_PRIVATE_KEY to GitHub Secrets."
  gpg --batch --passphrase "" --quick-generate-key \
    "DecanonicaledUbuntu APT Archive <apt@decanonicaled.local>" rsa4096 sign 2y
fi

KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/ {print $5; exit}')"

GPG_PASS_ARGS=(--batch --yes --pinentry-mode loopback)
if [[ -n "${APT_GPG_PASSPHRASE}" ]]; then
  GPG_PASS_ARGS+=(--passphrase "${APT_GPG_PASSPHRASE}")
else
  GPG_PASS_ARGS+=(--passphrase "")
fi

# Sign Release -> Release.gpg and InRelease
rm -f "${DIST_DIR}/Release.gpg" "${DIST_DIR}/InRelease"
gpg "${GPG_PASS_ARGS[@]}" --default-key "${KEY_ID}" -abs -o "${DIST_DIR}/Release.gpg" "${DIST_DIR}/Release"
gpg "${GPG_PASS_ARGS[@]}" --default-key "${KEY_ID}" --clearsign -o "${DIST_DIR}/InRelease" "${DIST_DIR}/Release"

# Export binary public key for /etc/apt/keyrings/decanonicaled.gpg
gpg --export "${KEY_ID}" > "${REPO_DIR}/decanonicaled.gpg"
gpg --armor --export "${KEY_ID}" > "${REPO_DIR}/decanonicaled.asc"

rm -rf "${GNUPGHOME}"
popd >/dev/null

# Write simple landing page for GitHub Pages
PKG_COUNT="$(grep -c '^Package: ' "${BIN_DIR}/Packages" || true)"
cat <<EOF > "${REPO_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>DecanonicaledUbuntu APT Repository</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 760px; margin: 3rem auto; padding: 0 1rem; line-height: 1.6; }
    pre { background: #f4f4f5; padding: 1rem; border-radius: 6px; overflow-x: auto; }
  </style>
</head>
<body>
  <h1>DecanonicaledUbuntu APT Repository</h1>
  <p>Distribution: <strong>${UBUNTU_CODENAME}</strong> | Architecture: <strong>amd64</strong> | Packages: <strong>${PKG_COUNT}</strong></p>
  <h2>Enable on an existing system</h2>
  <pre>curl -fsSL ./decanonicaled.gpg | sudo tee /etc/apt/keyrings/decanonicaled.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/decanonicaled.gpg] \$(pwd) ${UBUNTU_CODENAME} main" | sudo tee /etc/apt/sources.list.d/decanonicaled.list</pre>
</body>
</html>
EOF

echo "=== APT repo published (${PKG_COUNT} packages in ${UBUNTU_CODENAME}/main) ==="
