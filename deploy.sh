#!/usr/bin/env bash
#
# deploy.sh — Deploy a built REDCap module to the dev EC2 instance over SSM.
#
# Copies dist/redcap_rest_v<version>/ onto the target instance under
#   /var/www/html/redcap/modules/redcap_rest_v<version>/
# using scp tunneled through AWS Systems Manager (AWS-StartSSHSession). No S3,
# no open inbound port, no public IP, no long-lived SSH key.
#
# How the keyless transfer works:
#   1. Generate an ephemeral ed25519 keypair in a temp dir.
#   2. Install the public key into the login user's authorized_keys on the box
#      via an SSM RunShellScript command (short-lived).
#   3. scp the tarball to /tmp over an SSM SSH tunnel (ProxyCommand).
#   4. Run an SSM command to extract + install into the modules dir (sudo).
#   5. Always remove the ephemeral public key from the instance and delete the
#      local temp key material.
#
# Prerequisites (verified for this account/host):
#   - AWS CLI v2 authenticated (aws sts get-caller-identity)
#   - session-manager-plugin installed locally
#   - Target instance Online in SSM, sshd active, login user has NOPASSWD sudo
#
# ============================ IMPORTANT =====================================
# The target is an AWS Elastic Beanstalk instance (env naccdataredcapdev).
# Files placed directly on the instance are EPHEMERAL: they are lost on EB
# redeploy, platform update, or autoscaling instance replacement, and do not
# propagate to additional instances. Use this for quick DEV testing only. For
# a durable release, bake the module into the EB application source bundle.
# ============================================================================
#
# Usage:
#   ./deploy.sh                    # version from latest git tag
#   ./deploy.sh 2.0.1              # explicit version (must be built already)
#   ./deploy.sh 2.0.1 --yes        # skip confirmation prompt
#
# Config via env (defaults shown):
#   REGION=us-west-2
#   INSTANCE_ID=i-020f67cfd80946592
#   SSH_USER=ssm-user
#   MODULES_DIR=/var/www/html/redcap/modules
#   MODULE_OWNER=webapp:webapp

set -euo pipefail

# --- Config -----------------------------------------------------------------
REGION="${REGION:-us-west-2}"
INSTANCE_ID="${INSTANCE_ID:-i-020f67cfd80946592}"
SSH_USER="${SSH_USER:-ssm-user}"
MODULES_DIR="${MODULES_DIR:-/var/www/html/redcap/modules}"
MODULE_OWNER="${MODULE_OWNER:-webapp:webapp}"

MODULE_PREFIX="redcap_rest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"

# --- Args -------------------------------------------------------------------
ASSUME_YES=0
VERSION=""
for arg in "$@"; do
  case "${arg}" in
    --yes|-y) ASSUME_YES=1 ;;
    *) VERSION="${arg}" ;;
  esac
done

if [[ -z "${VERSION}" ]]; then
  VERSION="$(git -C "${SCRIPT_DIR}" describe --tags --abbrev=0 2>/dev/null || true)"
  if [[ -z "${VERSION}" ]]; then
    echo "ERROR: no version given and no git tag found. Pass a version, e.g. ./deploy.sh 2.0.1" >&2
    exit 1
  fi
fi
VERSION="${VERSION#v}"

RELEASE_NAME="${MODULE_PREFIX}_v${VERSION}"
RELEASE_DIR="${DIST_DIR}/${RELEASE_NAME}"
TARBALL="${DIST_DIR}/${RELEASE_NAME}.tar.gz"
REMOTE_TARBALL="/tmp/${RELEASE_NAME}.$$.tar.gz"

# --- Preflight --------------------------------------------------------------
if [[ ! -d "${RELEASE_DIR}" || ! -f "${TARBALL}" ]]; then
  echo "ERROR: build artifact not found for ${RELEASE_NAME}." >&2
  echo "       Run:  ./build.sh ${VERSION}" >&2
  exit 1
fi

for bin in aws ssh scp ssh-keygen session-manager-plugin; do
  command -v "${bin}" >/dev/null 2>&1 || { echo "ERROR: required tool '${bin}' not found on PATH." >&2; exit 1; }
done

echo "==> Checking AWS identity ..."
aws sts get-caller-identity --query "Arn" --output text

echo "==> Checking instance ${INSTANCE_ID} is Online in SSM ..."
PING="$(aws ssm describe-instance-information \
  --region "${REGION}" \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || true)"
if [[ "${PING}" != "Online" ]]; then
  echo "ERROR: instance ${INSTANCE_ID} is not Online in SSM (status: ${PING:-none})." >&2
  exit 1
fi

# --- Confirm ----------------------------------------------------------------
cat <<EOF

------------------------------------------------------------
 Deploy plan
   module:     ${RELEASE_NAME}
   instance:   ${INSTANCE_ID}  (region ${REGION})
   login user: ${SSH_USER}
   target:     ${MODULES_DIR}/${RELEASE_NAME}
   owner:      ${MODULE_OWNER}
   transport:  scp over SSM tunnel (ephemeral key), then sudo install

 NOTE: Elastic Beanstalk instance — this deployment is EPHEMERAL (dev testing).
------------------------------------------------------------
EOF

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  read -r -p "Proceed? [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# --- Ephemeral key + guaranteed cleanup -------------------------------------
KEYDIR="$(mktemp -d "${TMPDIR:-/tmp}/redcap-deploy.XXXXXX")"
KEYFILE="${KEYDIR}/id_ed25519"
PUBKEY_INSTALLED=0

cleanup() {
  # Best-effort removal of the ephemeral public key from the instance.
  if [[ "${PUBKEY_INSTALLED}" -eq 1 ]]; then
    echo "==> Removing ephemeral key from instance ..."
    local pub marker
    pub="$(cat "${KEYFILE}.pub" 2>/dev/null || true)"
    marker="$(printf '%s' "${pub}" | awk '{print $2}')"  # the key blob itself
    if [[ -n "${marker}" ]]; then
      run_ssm "grep -v '${marker}' /home/${SSH_USER}/.ssh/authorized_keys > /home/${SSH_USER}/.ssh/authorized_keys.tmp 2>/dev/null || true; mv /home/${SSH_USER}/.ssh/authorized_keys.tmp /home/${SSH_USER}/.ssh/authorized_keys 2>/dev/null || true; chown ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh/authorized_keys 2>/dev/null || true" "Remove ephemeral deploy key" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "${KEYDIR}"
}
trap cleanup EXIT

# run_ssm <shell-command-string> <comment> -> prints command stdout, returns status
run_ssm() {
  local cmd="$1" comment="$2" cid status
  local params
  params="$(printf '%s' "${cmd}" | python3 -c 'import json,sys; print(json.dumps({"commands":[sys.stdin.read()]}))')"
  cid="$(aws ssm send-command --region "${REGION}" --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" --comment "${comment}" \
    --parameters "${params}" --query "Command.CommandId" --output text)"
  local _i
  for _i in $(seq 1 40); do
    status="$(aws ssm get-command-invocation --region "${REGION}" --command-id "${cid}" \
      --instance-id "${INSTANCE_ID}" --query "Status" --output text 2>/dev/null || echo Pending)"
    case "${status}" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 3
  done
  aws ssm get-command-invocation --region "${REGION}" --command-id "${cid}" \
    --instance-id "${INSTANCE_ID}" --query "StandardOutputContent" --output text 2>/dev/null || true
  local err
  err="$(aws ssm get-command-invocation --region "${REGION}" --command-id "${cid}" \
    --instance-id "${INSTANCE_ID}" --query "StandardErrorContent" --output text 2>/dev/null || true)"
  if [[ -n "${err}" && "${err}" != "None" ]]; then echo "${err}" >&2; fi
  [[ "${status}" == "Success" ]]
}

echo "==> Generating ephemeral SSH key ..."
ssh-keygen -t ed25519 -N "" -q -f "${KEYFILE}" -C "redcap-deploy-${RELEASE_NAME}"
PUBKEY_CONTENT="$(cat "${KEYFILE}.pub")"

echo "==> Installing ephemeral public key on instance ..."
run_ssm "install -d -m 700 -o ${SSH_USER} -g ${SSH_USER} /home/${SSH_USER}/.ssh && printf '%s\n' '${PUBKEY_CONTENT}' >> /home/${SSH_USER}/.ssh/authorized_keys && chown ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.ssh/authorized_keys && chmod 600 /home/${SSH_USER}/.ssh/authorized_keys" \
  "Install ephemeral deploy key" >/dev/null \
  || { echo "ERROR: failed to install ephemeral key." >&2; exit 1; }
PUBKEY_INSTALLED=1

# SSH options: tunnel through SSM, don't touch known_hosts, use only our key.
SSH_PROXY="ProxyCommand aws ssm start-session --region ${REGION} --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
SSH_OPTS=(
  -o "${SSH_PROXY}"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -i "${KEYFILE}"
)

echo "==> Copying tarball to instance via SSM tunnel ..."
scp "${SSH_OPTS[@]}" "${TARBALL}" "${SSH_USER}@${INSTANCE_ID}:${REMOTE_TARBALL}" \
  || { echo "ERROR: scp over SSM failed." >&2; exit 1; }

echo "==> Installing module on instance ..."
INSTALL_CMD=$(cat <<EOF
set -e
umask 022
TMP=\$(mktemp -d /tmp/${RELEASE_NAME}.XXXXXX)
tar -C "\${TMP}" -xzf '${REMOTE_TARBALL}'
test -f "\${TMP}/${RELEASE_NAME}/config.json"
if [ -d '${MODULES_DIR}/${RELEASE_NAME}' ]; then
  sudo rm -rf '${MODULES_DIR}/${RELEASE_NAME}.bak'
  sudo mv '${MODULES_DIR}/${RELEASE_NAME}' '${MODULES_DIR}/${RELEASE_NAME}.bak'
fi
sudo mv "\${TMP}/${RELEASE_NAME}" '${MODULES_DIR}/${RELEASE_NAME}'
sudo chown -R ${MODULE_OWNER} '${MODULES_DIR}/${RELEASE_NAME}'
sudo find '${MODULES_DIR}/${RELEASE_NAME}' -type d -exec chmod 755 {} +
sudo find '${MODULES_DIR}/${RELEASE_NAME}' -type f -exec chmod 644 {} +
sudo rm -rf '${MODULES_DIR}/${RELEASE_NAME}.bak'
rm -rf "\${TMP}" '${REMOTE_TARBALL}'
echo "Deployed ${RELEASE_NAME}:"
ls -la '${MODULES_DIR}/${RELEASE_NAME}'
EOF
)

if run_ssm "${INSTALL_CMD}" "Install ${RELEASE_NAME}"; then
  echo "==> Done. ${RELEASE_NAME} deployed to ${INSTANCE_ID}."
  echo "    Reminder: enable/upgrade the module version in REDCap Control Center if needed."
else
  echo "DEPLOY FAILED during install step." >&2
  exit 1
fi
