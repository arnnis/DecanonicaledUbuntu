#!/bin/bash
set -euo pipefail

NEW_DEBS_DIR="${NEW_DEBS_DIR:-$(pwd)/farm-debs}"
WORK_DIR="${WORK_DIR:-$(pwd)/release-shards}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
SHARD_PREFIX="${SHARD_PREFIX:-apt-pool-${UBUNTU_CODENAME}}"
MAX_DEBS_PER_SHARD="${MAX_DEBS_PER_SHARD:-800}"
APT_GPG_PRIVATE_KEY="${APT_GPG_PRIVATE_KEY:-}"
APT_GPG_PASSPHRASE="${APT_GPG_PASSPHRASE:-}"

mkdir -p "${WORK_DIR}"

# 1. Setup GPG keyring for signing all shards
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
  gpg --batch --passphrase "" --quick-generate-key \
    "DecanonicaledUbuntu APT Archive <apt@decanonicaled.local>" rsa4096 sign 2y
fi

KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/ {print $5; exit}')"
gpg --export "${KEY_ID}" > "${WORK_DIR}/decanonicaled.gpg"
gpg --armor --export "${KEY_ID}" > "${WORK_DIR}/decanonicaled.asc"

# 2. Discover existing shard releases (apt-pool-<codename>-01, -02, ...)
EXISTING_SHARDS_FILE="${WORK_DIR}/existing_shards.txt"
gh release list --limit 100 --json tagName -q '.[].tagName' \
  | grep -E "^${SHARD_PREFIX}-[0-9]{2}$" \
  | sort > "${EXISTING_SHARDS_FILE}" || true

mkdir -p "${WORK_DIR}/shards"
while IFS= read -r tag; do
  [[ -z "${tag}" ]] && continue
  sdir="${WORK_DIR}/shards/${tag}"
  mkdir -p "${sdir}"
  gh release download "${tag}" -p "Packages" -D "${sdir}" 2>/dev/null || : > "${sdir}/Packages"
done < "${EXISTING_SHARDS_FILE}"

# 3. Sanitize new .deb filenames (+ and ~ -> .) so GitHub Release asset URLs match Packages Filename
STAGED_DIR="${WORK_DIR}/staged-debs"
rm -rf "${STAGED_DIR}"
mkdir -p "${STAGED_DIR}"

if [[ -d "${NEW_DEBS_DIR}" ]] && compgen -G "${NEW_DEBS_DIR}/*.deb" >/dev/null; then
  for f in "${NEW_DEBS_DIR}"/*.deb; do
    base="$(basename "${f}")"
    safe="$(printf '%s' "${base}" | tr '+~:' '...')"
    cp -f "${f}" "${STAGED_DIR}/${safe}"
  done
fi

# 4. Assign new .debs to shards (max 800 per shard) and update Packages stanzas
DIRTY_SHARDS_FILE="${WORK_DIR}/dirty_shards.txt"
DELETE_ASSETS_FILE="${WORK_DIR}/delete_assets.txt"
: > "${DIRTY_SHARDS_FILE}"
: > "${DELETE_ASSETS_FILE}"

python3 - "${WORK_DIR}/shards" "${STAGED_DIR}" "${SHARD_PREFIX}" "${MAX_DEBS_PER_SHARD}" "${DIRTY_SHARDS_FILE}" "${DELETE_ASSETS_FILE}" <<'PY'
import os
import shutil
import subprocess
import sys

shards_root, staged_dir, prefix, max_per_shard, dirty_out, delete_out = sys.argv[1:7]
max_per_shard = int(max_per_shard)

def parse_packages(pkg_file):
    stanzas = {}
    if not os.path.exists(pkg_file):
        return stanzas
    with open(pkg_file, "r", encoding="utf-8", errors="ignore") as f:
        blocks = [b.strip() for b in f.read().split("\n\n") if b.strip()]
    for b in blocks:
        pkg = ver = arch = fname = ""
        for line in b.splitlines():
            if line.startswith("Package: "):
                pkg = line.split(": ", 1)[1].strip()
            elif line.startswith("Version: "):
                ver = line.split(": ", 1)[1].strip()
            elif line.startswith("Architecture: "):
                arch = line.split(": ", 1)[1].strip()
            elif line.startswith("Filename: "):
                fname = os.path.basename(line.split(": ", 1)[1].strip())
                fname = fname.replace("+", ".").replace("~", ".").replace(":", ".")
                b = b.replace(line, f"Filename: {fname}")
        if pkg and arch:
            stanzas[(pkg, arch)] = (ver, fname, b)
    return stanzas

# Load existing shards
shards = {}
for tag in sorted(os.listdir(shards_root)):
    pfile = os.path.join(shards_root, tag, "Packages")
    shards[tag] = parse_packages(pfile)

# Scan new .debs with dpkg-scanpackages
new_files = sorted(f for f in os.listdir(staged_dir) if f.endswith(".deb"))
new_stanzas = {}
if new_files:
    out = subprocess.check_output(["dpkg-scanpackages", "--multiversion", "."], cwd=staged_dir, text=True)
    for b in [x.strip() for x in out.split("\n\n") if x.strip()]:
        pkg = ver = arch = fname = ""
        fixed_lines = []
        for line in b.splitlines():
            if line.startswith("Package: "):
                pkg = line.split(": ", 1)[1].strip()
            elif line.startswith("Version: "):
                ver = line.split(": ", 1)[1].strip()
            elif line.startswith("Architecture: "):
                arch = line.split(": ", 1)[1].strip()
            elif line.startswith("Filename: "):
                fname = os.path.basename(line.split(": ", 1)[1].strip())
                fname = fname.replace("+", ".").replace("~", ".").replace(":", ".")
                b = b.replace(line, f"Filename: {fname}")
                line = f"Filename: {fname}"
            fixed_lines.append(line)
        if pkg and arch:
            # Keep highest version if duplicate in staged
            key = (pkg, arch)
            if key in new_stanzas:
                old_ver = new_stanzas[key][0]
                if subprocess.call(["dpkg", "--compare-versions", ver, "gt", old_ver]) != 0:
                    continue
            new_stanzas[key] = (ver, fname, "\n".join(fixed_lines))

dirty = set()
deletes = []

def next_shard_tag():
    idx = 1
    while f"{prefix}-{idx:02d}" in shards:
        idx += 1
    tag = f"{prefix}-{idx:02d}"
    shards[tag] = {}
    os.makedirs(os.path.join(shards_root, tag), exist_ok=True)
    return tag

for key, (ver, fname, block) in sorted(new_stanzas.items()):
    target_tag = None
    # Check if already present in an existing shard
    for tag, sdata in shards.items():
        if key in sdata:
            old_ver, old_fname, _ = sdata[key]
            target_tag = tag
            if old_fname != fname:
                deletes.append((tag, old_fname))
            break
    # Otherwise place in first shard with room (< max_per_shard)
    if target_tag is None:
        for tag in sorted(shards.keys()):
            if len(shards[tag]) < max_per_shard:
                target_tag = tag
                break
        if target_tag is None:
            target_tag = next_shard_tag()

    shards[target_tag][key] = (ver, fname, block)
    os.makedirs(os.path.join(shards_root, target_tag, "upload"), exist_ok=True)
    shutil.copy2(os.path.join(staged_dir, fname), os.path.join(shards_root, target_tag, "upload", fname))
    dirty.add(target_tag)

# Write updated Packages for dirty shards
for tag in sorted(dirty):
    pfile = os.path.join(shards_root, tag, "Packages")
    with open(pfile, "w", encoding="utf-8") as f:
        for key in sorted(shards[tag].keys()):
            f.write(shards[tag][key][2] + "\n\n")

with open(dirty_out, "w", encoding="utf-8") as f:
    for tag in sorted(dirty):
        f.write(tag + "\n")

with open(delete_out, "w", encoding="utf-8") as f:
    for tag, fname in deletes:
        f.write(f"{tag}\t{fname}\n")

print(f"Total shards: {len(shards)} | Dirty shards to publish: {len(dirty)}")
PY

# 5. Delete superseded assets from dirty shards
while IFS=$'\t' read -r tag old_fname; do
  [[ -z "${tag}" ]] && continue
  gh release delete-asset "${tag}" "${old_fname}" --yes 2>/dev/null || true
done < "${DELETE_ASSETS_FILE}"

# 6. Sign & upload each dirty shard
GPG_PASS_ARGS=(--batch --yes --pinentry-mode loopback)
if [[ -n "${APT_GPG_PASSPHRASE}" ]]; then
  GPG_PASS_ARGS+=(--passphrase "${APT_GPG_PASSPHRASE}")
else
  GPG_PASS_ARGS+=(--passphrase "")
fi

while IFS= read -r tag; do
  [[ -z "${tag}" ]] && continue
  sdir="${WORK_DIR}/shards/${tag}"
  echo "=== Publishing shard release: ${tag} ==="

  pushd "${sdir}" >/dev/null
  gzip -k -f -9 Packages

  apt-ftparchive \
    -o "APT::FTPArchive::Release::Origin=DecanonicaledUbuntu" \
    -o "APT::FTPArchive::Release::Label=DecanonicaledUbuntu" \
    -o "APT::FTPArchive::Release::Suite=${UBUNTU_CODENAME}" \
    -o "APT::FTPArchive::Release::Codename=${UBUNTU_CODENAME}" \
    -o "APT::FTPArchive::Release::Architectures=amd64" \
    -o "APT::FTPArchive::Release::Components=main" \
    release . > Release

  rm -f Release.gpg InRelease
  gpg "${GPG_PASS_ARGS[@]}" --default-key "${KEY_ID}" -abs -o Release.gpg Release
  gpg "${GPG_PASS_ARGS[@]}" --default-key "${KEY_ID}" --clearsign -o InRelease Release

  # Create release if it does not exist yet
  if ! gh release view "${tag}" >/dev/null 2>&1; then
    gh release create "${tag}" \
      --title "APT Pool ${UBUNTU_CODENAME} (${tag##*-})" \
      --notes "Automated sharded APT repository for ${UBUNTU_CODENAME} (max ${MAX_DEBS_PER_SHARD} .debs per shard)." \
      --prerelease=false
  fi

  # Helper to upload with retry + backoff on GitHub secondary rate limits
  upload_with_retry() {
    local asset_path="$1"
    local attempt=1
    local max_attempts=6
    while (( attempt <= max_attempts )); do
      if gh release upload "${tag}" "${asset_path}" --clobber 2>&1; then
        return 0
      fi
      local wait_sec=$(( attempt * 60 ))
      echo "Upload failed/rate-limited for $(basename "${asset_path}") (attempt ${attempt}/${max_attempts}); sleeping ${wait_sec}s..."
      sleep "${wait_sec}"
      ((attempt++))
    done
    echo "ERROR: Failed to upload $(basename "${asset_path}") after ${max_attempts} attempts" >&2
    return 1
  }

  # Upload metadata
  for meta in Packages Packages.gz Release Release.gpg InRelease "${WORK_DIR}/decanonicaled.gpg"; do
    upload_with_retry "${meta}"
    sleep 0.5
  done

  # Upload new .debs (skipping ones already present on the release to avoid redundant API calls)
  if [[ -d upload ]] && compgen -G "upload/*.deb" >/dev/null; then
    EXISTING_ASSETS="$(gh release view "${tag}" --json assets -q '.assets[].name' 2>/dev/null || true)"
    for deb in upload/*.deb; do
      deb_name="$(basename "${deb}")"
      if printf '%s\n' "${EXISTING_ASSETS}" | grep -Fxq "${deb_name}"; then
        continue
      fi
      upload_with_retry "${deb}"
      sleep 0.6
    done
  fi
  popd >/dev/null
done < "${DIRTY_SHARDS_FILE}"

# 7. Output full list of shard tags
ls -1 "${WORK_DIR}/shards" | sort > "${WORK_DIR}/shards.txt"
rm -rf "${GNUPGHOME}"

echo "=== Published shards: ==="
cat "${WORK_DIR}/shards.txt"
