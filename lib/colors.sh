#!/bin/bash
# Colors and formatting

RED='\033[0;31m'    GREEN='\033[0;32m'
YELLOW='\033[1;33m' CYAN='\033[0;36m'
BOLD='\033[1m'      DIM='\033[2m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[kit]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[kit]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[kit]${NC} $1"; }
log_error() { echo -e "${RED}[kit]${NC} $1"; }
log_step()  { echo -e "${DIM}  →${NC} $1"; }
