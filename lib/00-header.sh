#!/bin/bash

# =========================================================================
# Ubuntu Server Manager (PHP/Laravel Stack) — pushit
# =========================================================================
# SOURCE-OF-TRUTH: lib/*.sh  (edit there, then ./build.sh)
# GENERATED FILE:  server_manager.sh is built by build.sh — DO NOT EDIT DIRECTLY
# =========================================================================

# NOTE: 'set -e' is intentionally NOT used. This is an interactive menu tool;
# a single failing command (e.g. listing an empty crontab) must not kill the
# whole session.

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Single source of truth for the PHP version (packages, FPM pool and socket)
PHP_VERSION="8.4"
# Single source of truth for the Node.js major version (NodeSource setup script)
NODE_VERSION="22"

PUSHIT_BIN="/usr/local/bin/pushit"
PUSHIT_CONFIG="/etc/pushit.conf"
PUSHIT_VERSION="0.1.0"
PUSHIT_REPO="homoweb/server-manager-sh"
PUSHIT_REMOTE_URL="https://raw.githubusercontent.com/${PUSHIT_REPO}/main/server_manager.sh"
PUSHIT_UPDATE_TTL=21600
PUSHIT_UPDATE_CACHE_DIR="/var/cache/pushit"
PUSHIT_UPDATE_CACHE_FILE="${PUSHIT_UPDATE_CACHE_DIR}/update.json"
PUSHIT_DL_DIR="/var/lib/pushit/downloads"
PUSHIT_DL_PORT="8787"
PUSHIT_DL_SERVER="/usr/local/bin/pushit-dl-server.py"
PUSHIT_DL_LOG="/var/log/pushit-dl.log"
