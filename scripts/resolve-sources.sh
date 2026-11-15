#!/bin/bash
set -euo pipefail

UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
FLAVOR="${FLAVOR:-gnome-minimal}"
BUILD_SCOPE="${BUILD_SCOPE:-core}"
MAX_WORKERS="${MAX_WORKERS:-18}"
EXISTING_PACKAGES_URLS="${EXISTING_PACKAGES_URLS:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Resolving source packages (codename=${UBUNTU_CODENAME}, flavor=${FLAVOR}, scope=${BUILD_SCOPE})..." >&2

# Run APT resolution inside a matching Ubuntu container so dependency resolution
# matches the target release (e.g. resolute 26.04) rather than the runner host.
if command -v docker >/dev/null 2>&1 && [[ -z "${IN_TARGET_CONTAINER:-}" ]]; then
  exec docker run --rm \
    -e IN_TARGET_CONTAINER=1 \
    -e UBUNTU_CODENAME="${UBUNTU_CODENAME}" \
    -e FLAVOR="${FLAVOR}" \
    -e BUILD_SCOPE="${BUILD_SCOPE}" \
    -e MAX_WORKERS="${MAX_WORKERS}" \
    -e EXISTING_PACKAGES_URLS="${EXISTING_PACKAGES_URLS}" \
    -v "${REPO_ROOT}:/workspace:ro" \
    -w /workspace \
    "ubuntu:${UBUNTU_CODENAME}" \
    bash /workspace/scripts/resolve-sources.sh
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >&2
apt-get install -y -qq curl ca-certificates python3 >/dev/null 2>&1

cat <<EOF > /etc/apt/sources.list.d/decanonicaled-src.list
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

apt-get update -qq >&2

RAW_SOURCES_FILE="$(mktemp)"
EXISTING_PKGS_FILE="$(mktemp)"
trap 'rm -f "${RAW_SOURCES_FILE}" "${EXISTING_PKGS_FILE}"' EXIT

if [[ "${BUILD_SCOPE}" == "core" ]]; then
  grep -vE '^\s*(#|$)' "${REPO_ROOT}/config/source-packages/core.txt" | sort -u > "${RAW_SOURCES_FILE}"
elif [[ "${BUILD_SCOPE}" == "full" ]]; then
  SEED_PKGS=(ubuntu-minimal ubuntu-standard casper network-manager sudo curl ca-certificates gnupg)
  case "${FLAVOR}" in
    gnome-minimal)
      SEED_PKGS+=(ubuntu-desktop-minimal gnome-terminal nautilus gnome-text-editor calamares)
      ;;
    xfce)
      SEED_PKGS+=(xubuntu-core xfce4-terminal thunar calamares)
      ;;
    server)
      SEED_PKGS+=(openssh-server htop tmux)
      ;;
  esac

  BIN_PKGS=$(apt-cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances "${SEED_PKGS[@]}" \
    | grep -E '^\w' | grep -vE '^(snapd|ubuntu-report|popularity-contest|whoopsie|apport|kerneloops|ubuntu-advantage-tools|ubuntu-pro-client)$' \
    | sort -u)

  apt-cache show ${BIN_PKGS} 2>/dev/null \
    | awk '
      /^Package: / { pkg=$2; src="" }
      /^Source: /  { src=$2 }
      /^$/ { if (pkg != "") { print (src != "" ? src : pkg); pkg=""; src="" } }
      END { if (pkg != "") print (src != "" ? src : pkg) }
    ' | sort -u > "${RAW_SOURCES_FILE}"
else
  echo "Unknown BUILD_SCOPE: ${BUILD_SCOPE} (expected core or full)" >&2
  exit 1
fi

if [[ -n "${EXISTING_PACKAGES_URLS}" ]]; then
  echo "Checking existing APT shard indexes..." >&2
  : > "${EXISTING_PKGS_FILE}"
  for url in ${EXISTING_PACKAGES_URLS}; do
    if curl -fsSL "${url}" | gzip -d >> "${EXISTING_PKGS_FILE}" 2>/dev/null; then
      echo "" >> "${EXISTING_PKGS_FILE}"
      echo "Loaded shard index: ${url}" >&2
    fi
  done
fi

python3 - "${RAW_SOURCES_FILE}" "${EXISTING_PKGS_FILE}" "${MAX_WORKERS}" <<'PY'
import json
import re
import subprocess
import sys

raw_path = sys.argv[1]
existing_path = sys.argv[2]
max_workers = int(sys.argv[3])

with open(raw_path, "r", encoding="utf-8") as f:
    all_pkgs = [line.strip() for line in f if line.strip()]

existing_src_versions = {}
with open(existing_path, "r", encoding="utf-8", errors="ignore") as f:
    cur_pkg = ""
    cur_src = ""
    cur_ver = ""
    for line in f:
        line = line.rstrip("\n")
        if line.startswith("Package: "):
            cur_pkg = line.split(": ", 1)[1].strip()
        elif line.startswith("Source: "):
            cur_src = line.split(": ", 1)[1].strip().split(" ")[0]
        elif line.startswith("Version: "):
            cur_ver = line.split(": ", 1)[1].strip()
        elif line == "":
            if cur_pkg and cur_ver:
                src_name = cur_src or cur_pkg
                base_ver = re.sub(r"\+decanonicaled\d*$", "", cur_ver)
                existing_src_versions[src_name] = base_ver
            cur_pkg = cur_src = cur_ver = ""

pkgs_to_build = []
if existing_src_versions:
    for p in all_pkgs:
        if p not in existing_src_versions:
            pkgs_to_build.append(p)
            continue
        try:
            out = subprocess.check_output(
                ["apt-cache", "showsrc", p], text=True, stderr=subprocess.DEVNULL
            )
            upstream_vers = re.findall(r"^Version:\s*(\S+)", out, re.MULTILINE)
            if not upstream_vers:
                pkgs_to_build.append(p)
                continue
            latest_upstream = upstream_vers[-1]
            if existing_src_versions[p] != latest_upstream:
                pkgs_to_build.append(p)
        except subprocess.CalledProcessError:
            pkgs_to_build.append(p)
else:
    pkgs_to_build = all_pkgs

print(f"Packages needing build: {len(pkgs_to_build)} / {len(all_pkgs)}", file=sys.stderr)

heavy_prefixes = (
    "linux", "gcc-", "llvm-toolchain", "rustc", "firefox",
    "chromium", "libreoffice", "webkit2gtk", "mesa", "qt6-", "qt5-"
)

heavy = []
normal = []
for p in pkgs_to_build:
    if any(p == h or p.startswith(h) for h in heavy_prefixes):
        heavy.append(p)
    else:
        normal.append(p)

batches = []
for p in heavy:
    batches.append({"id": f"heavy-{p}", "packages": p})

remaining_slots = max(1, max_workers - len(batches))
if normal:
    buckets = [[] for _ in range(min(remaining_slots, len(normal)))]
    for idx, p in enumerate(normal):
        buckets[idx % len(buckets)].append(p)
    for idx, b in enumerate(buckets, start=1):
        batches.append({"id": f"batch-{idx}", "packages": " ".join(b)})

print(json.dumps(batches))
PY
