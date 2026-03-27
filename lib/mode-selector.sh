#!/bin/bash
# =============================================================================
# Mode Selector — The SDK decision engine
# =============================================================================
#
# Automatically selects the execution mode based on task properties.
# The logic is a decision tree:
#
#   ┌─ coordination: required ──────────────→ Mode 4 (Agent Teams)
#   │
#   ├─ risk: high ──────────────────────────→ Mode 1 (Supervised)
#   │
#   ├─ scope: full_codebase ────────────────→ Mode 1 (Supervised)
#   │
#   ├─ type: chore + risk: low ─────────────→ Mode 3 (Fire & Forget)
#   │
#   ├─ type: review ────────────────────────→ Mode 4 (Agent Teams)*
#   │     * reviews benefit from multi-perspective coordination
#   │
#   ├─ scope: single_feature + risk: low ──→ Mode 3 (Fire & Forget)
#   │
#   ├─ scope: single_feature + risk: med ──→ Mode 2 (Semi-auto)
#   │
#   └─ default ─────────────────────────────→ Mode 2 (Semi-auto)
#
# The user can always override with --mode N
# =============================================================================

set -euo pipefail

select_mode() {
  # Normalize all inputs to lowercase to prevent case-sensitivity issues
  local scope=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  local coordination=$(echo "$2" | tr '[:upper:]' '[:lower:]')
  local risk=$(echo "$3" | tr '[:upper:]' '[:lower:]')
  local task_type=$(echo "$4" | tr '[:upper:]' '[:lower:]')

  # Rule 1: Coordination required → Agent Teams
  if [ "$coordination" = "required" ]; then
    echo "4"
    return
  fi

  # Rule 2: High risk → always supervised
  if [ "$risk" = "high" ]; then
    echo "1"
    return
  fi

  # Rule 3: Full codebase → supervised (too risky for auto)
  if [ "$scope" = "full_codebase" ]; then
    echo "1"
    return
  fi

  # Rule 4: Chores (lint, format, tests, docs) + low risk → fire & forget
  if [ "$task_type" = "chore" ] && [ "$risk" = "low" ]; then
    echo "3"
    return
  fi

  # Rule 5: Reviews benefit from multi-perspective coordination
  if [ "$task_type" = "review" ]; then
    echo "4"
    return
  fi

  # Rule 6: Single feature + low risk → fire & forget
  if [ "$scope" = "single_feature" ] && [ "$risk" = "low" ]; then
    echo "3"
    return
  fi

  # Rule 7: Single feature + medium risk → semi-auto
  if [ "$scope" = "single_feature" ] && [ "$risk" = "medium" ]; then
    echo "2"
    return
  fi

  # Rule 8: Cross-layer without explicit coordination → semi-auto
  # (the user said coordination: none but scope is cross-layer)
  if [ "$scope" = "cross_layer" ]; then
    echo "2"
    return
  fi

  # Default: semi-auto (safest general-purpose mode)
  echo "2"
}

explain_mode_selection() {
  local mode="$1"
  local scope="$2"
  local coordination="$3"
  local risk="$4"
  local task_type="${5:-}"

  echo -e "  ${DIM}Reason:${NC}"
  case "$mode" in
    1)
      if [ "$risk" = "high" ]; then
        echo -e "  ${DIM}  Risk=$risk → human supervision required${NC}"
      elif [ "$scope" = "full_codebase" ]; then
        echo -e "  ${DIM}  Scope=$scope → too broad for auto${NC}"
      else
        echo -e "  ${DIM}  Scope/risk → supervision required${NC}"
      fi
      ;;
    2)
      echo -e "  ${DIM}  Scope=$scope + Risk=$risk → auto-accept with monitoring${NC}"
      ;;
    3)
      if [ "$scope" = "single_feature" ] && [ "$risk" = "low" ]; then
        echo -e "  ${DIM}  Isolated feature + low risk → safe for headless${NC}"
      else
        echo -e "  ${DIM}  Routine task + low risk → fire & forget${NC}"
      fi
      ;;
    4)
      if [ "$coordination" = "required" ]; then
        echo -e "  ${DIM}  Coordination required → Agent Teams with team lead${NC}"
      else
        echo -e "  ${DIM}  Type=$task_type → benefits from multiple perspectives${NC}"
      fi
      ;;
  esac
}
