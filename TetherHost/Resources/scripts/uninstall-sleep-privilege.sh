#!/bin/bash
# Keep in sync with TetherHost/SleepPrivilegeScripts.swift
set -euo pipefail

USER_ID="$(/usr/bin/id -u)"
SUPPORT_DIR="${HOME}/Library/Application Support/Tether"
AGENT_LABEL="com.tether.host.sleep-recovery"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
RECOVERY_DST="${SUPPORT_DIR}/tether-sleep-recovery.sh"
JOURNAL="${SUPPORT_DIR}/sleep-journal.json"
SUDOERS_PATH="/etc/sudoers.d/tether-sleep"
PMSET="/usr/bin/pmset"

echo ""
echo "Tether — remove lid-closed awake"
echo ""

if [[ -f "${RECOVERY_DST}" ]]; then
  printf '0\n' > "${SUPPORT_DIR}/sleep-control.request"
  /bin/bash "${RECOVERY_DST}" 2>/dev/null || true
fi
/usr/bin/sudo -n "${PMSET}" -a disablesleep 0 2>/dev/null || true
/bin/rm -f "${JOURNAL}"
/bin/rm -f "${SUPPORT_DIR}/sleep-control.request" "${SUPPORT_DIR}/sleep-control.result"
/bin/rm -f /tmp/tether-sleep-recovery.log

launchctl bootout "gui/${USER_ID}/${AGENT_LABEL}" 2>/dev/null || true
/bin/rm -f "${AGENT_PLIST}"
/bin/rm -f "${RECOVERY_DST}"
/bin/rm -f "${SUPPORT_DIR}/sleep-privilege.installed"

if [[ -f "${SUDOERS_PATH}" ]]; then
  echo "Enter your password to remove the privilege rule."
  /usr/bin/sudo -k
  /usr/bin/sudo /bin/rm -f "${SUDOERS_PATH}"
fi

echo "Removed."
echo ""
