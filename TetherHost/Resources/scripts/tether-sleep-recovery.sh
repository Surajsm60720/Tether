#!/bin/bash
# Keep in sync with TetherHost/SleepPrivilegeScripts.swift
set -euo pipefail

SUPPORT="${HOME}/Library/Application Support/Tether"
JOURNAL="${SUPPORT}/sleep-journal.json"
REQUEST="${SUPPORT}/sleep-control.request"
RESULT="${SUPPORT}/sleep-control.result"
PMSET="/usr/bin/pmset"
SUDO="/usr/bin/sudo"

apply_request() {
  if [[ ! -f "${REQUEST}" ]]; then
    return 0
  fi
  local value
  value="$(/usr/bin/tr -d '[:space:]' < "${REQUEST}" || true)"
  /bin/rm -f "${REQUEST}"
  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    printf 'fail bad-request\n' > "${RESULT}"
    return 0
  fi
  if "${SUDO}" -n "${PMSET}" -a disablesleep "${value}"; then
    printf 'ok %s\n' "${value}" > "${RESULT}"
  else
    printf 'fail pmset\n' > "${RESULT}"
  fi
}

recover_if_needed() {
  if [[ ! -f "${JOURNAL}" ]]; then
    return 0
  fi
  read_field() {
    local key="$1"
    /usr/bin/python3 - <<PY
import json, sys
try:
    with open("${JOURNAL}") as f:
        data = json.load(f)
except Exception:
    sys.exit(2)
value = data.get("${key}")
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
  }
  local enabled pid prev
  enabled="$(read_field disablesleepEnabled || true)"
  if [[ "${enabled}" != "true" ]]; then
    return 0
  fi
  pid="$(read_field ownerPID || true)"
  if [[ -n "${pid}" && "${pid}" != "" ]]; then
    if /bin/kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
  fi
  if /usr/bin/pgrep -xq "TetherHost" 2>/dev/null; then
    return 0
  fi
  prev="$(read_field lowPowerModePrevious || true)"
  "${SUDO}" -n "${PMSET}" -a disablesleep 0 || true
  if [[ "${prev}" == "true" ]]; then
    "${SUDO}" -n "${PMSET}" -b lowpowermode 1 || true
  elif [[ "${prev}" == "false" ]]; then
    "${SUDO}" -n "${PMSET}" -b lowpowermode 0 || true
  fi
  /bin/rm -f "${JOURNAL}"
}

apply_request
recover_if_needed
exit 0
