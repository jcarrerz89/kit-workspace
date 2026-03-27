#!/usr/bin/env bash
# kit-workspace installer
set -euo pipefail

KWS_HOME="${HOME}/.kit-workspace"
INSTALL_BIN="/usr/local/bin/kit-workspace"
KWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create ~/.kit-workspace/ directory structure
mkdir -p "${KWS_HOME}"/{jobs,state,logs}

# Symlink the binary
ln -sf "${KWS_DIR}/kit-workspace" "${INSTALL_BIN}"

# Set executable permissions
chmod +x "${KWS_DIR}/kit-workspace"
chmod +x "${KWS_DIR}/drivers/"*.sh
chmod +x "${KWS_DIR}/lib/"*.sh

echo "kit-workspace installed. Run: kit-workspace init"
