#!/usr/bin/env bash
#
# build.sh — Assemble a deployable REDCap External Module directory.
#
# Produces:  dist/redcap_rest_v<version>/   (runtime files only)
#            dist/redcap_rest_v<version>.tar.gz
#
# The <version> defaults to the most recent git tag (e.g. 2.0.0). REDCap
# identifies a module by its directory name suffix `_v<version>`, so the
# version here becomes the deployed module version.
#
# Usage:
#   ./build.sh                 # version from latest git tag
#   ./build.sh 2.0.1           # explicit version
#   VERSION=2.0.1 ./build.sh   # explicit version via env
#
# This script does NOT touch any remote host. See deploy.sh for that.

set -euo pipefail

MODULE_PREFIX="redcap_rest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"

# --- Determine version -------------------------------------------------------
VERSION="${1:-${VERSION:-}}"
if [[ -z "${VERSION}" ]]; then
  if VERSION="$(git -C "${SCRIPT_DIR}" describe --tags --abbrev=0 2>/dev/null)"; then
    :
  else
    echo "ERROR: no version given and no git tag found. Pass a version, e.g. ./build.sh 2.0.1" >&2
    exit 1
  fi
fi
# Strip a leading 'v' if present (tags are bare like 2.0.0, but be tolerant).
VERSION="${VERSION#v}"

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.].+)?$ ]]; then
  echo "ERROR: version '${VERSION}' does not look like semver (MAJOR.MINOR.PATCH)." >&2
  exit 1
fi

RELEASE_NAME="${MODULE_PREFIX}_v${VERSION}"
RELEASE_DIR="${DIST_DIR}/${RELEASE_NAME}"
TARBALL="${DIST_DIR}/${RELEASE_NAME}.tar.gz"

# --- Files/paths that are NOT part of the runtime module ---------------------
# Everything else in the repo root is shipped. Using an exclude-list means new
# runtime files are picked up automatically without editing this script.
EXCLUDES=(
  ".git"
  ".gitignore"
  "composer.json"
  "composer.lock"
  "phpunit.xml"
  "tests"
  "scratch"
  "dist"
  "build.sh"
  "deploy.sh"
  ".vscode"
  ".idea"
  ".DS_Store"
)

echo "==> Building ${RELEASE_NAME}"
echo "    source:  ${SCRIPT_DIR}"
echo "    output:  ${RELEASE_DIR}"

# --- Assemble ---------------------------------------------------------------
rm -rf "${RELEASE_DIR}" "${TARBALL}"
mkdir -p "${RELEASE_DIR}"

# Build rsync exclude args.
RSYNC_EXCLUDES=()
for e in "${EXCLUDES[@]}"; do
  RSYNC_EXCLUDES+=("--exclude=${e}")
done

rsync -a "${RSYNC_EXCLUDES[@]}" \
  --exclude="${RELEASE_NAME}" \
  "${SCRIPT_DIR}/" "${RELEASE_DIR}/"

# --- Sanity check: config.json must be present and valid ---------------------
if [[ ! -f "${RELEASE_DIR}/config.json" ]]; then
  echo "ERROR: config.json missing from build output." >&2
  exit 1
fi
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open('${RELEASE_DIR}/config.json'))" \
    || { echo "ERROR: config.json is not valid JSON." >&2; exit 1; }
fi

# --- Sanity check: required runtime files -----------------------------------
REQUIRED=(
  "REDCapREST.php"
  "OAuth2.php"
  "OAuth2ClientCredentials.php"
  "Instruction.php"
  "ModuleSettingsManager.php"
  "summary.php"
  "export_import.php"
  "example.php"
  "config.json"
)
missing=0
for f in "${REQUIRED[@]}"; do
  if [[ ! -f "${RELEASE_DIR}/${f}" ]]; then
    echo "ERROR: required runtime file missing from build: ${f}" >&2
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || exit 1

# --- Package ----------------------------------------------------------------
# Tar with the versioned directory as the top-level entry so it extracts
# straight into a modules/ directory.
#
# --no-xattrs: macOS stamps files with the com.apple.provenance extended
# attribute (Gatekeeper). Apple's bsdtar would otherwise store it as a
# LIBARCHIVE.xattr.com.apple.provenance pax header, which GNU tar on the Linux
# target does not recognise and warns about once per file on extract. Excluding
# xattrs keeps those (harmless but noisy) warnings out of the deploy output.
# COPYFILE_DISABLE stops macOS from adding ._* AppleDouble entries too.
TAR_OPTS=()
if tar --no-xattrs -cf /dev/null -T /dev/null >/dev/null 2>&1; then
  TAR_OPTS+=(--no-xattrs)
fi
COPYFILE_DISABLE=1 tar "${TAR_OPTS[@]}" -C "${DIST_DIR}" -czf "${TARBALL}" "${RELEASE_NAME}"

echo "==> Contents:"
( cd "${RELEASE_DIR}" && find . -type f | sort | sed 's/^/      /' )

echo "==> Built:"
echo "    dir:     ${RELEASE_DIR}"
echo "    tarball: ${TARBALL}"
echo
echo "Version: ${VERSION}"
