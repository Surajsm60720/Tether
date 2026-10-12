import Foundation

/// Shell payloads shipped inside the Host binary so install never depends on Resources layout.
enum SleepPrivilegeScripts {
    static let installFileName = "install-sleep-privilege.sh"
    static let uninstallFileName = "uninstall-sleep-privilege.sh"
    static let recoveryFileName = "tether-sleep-recovery.sh"

    /// Runs outside the app sandbox (LaunchAgent). Handles pmset requests from Host, then recovery.
    static let recovery = #"""
#!/bin/bash
# Tether sleep agent — runs as your user via LaunchAgent (not sandboxed).
# 1) Apply sleep-control.request from Host (sudo pmset) — sandbox cannot do this reliably.
# 2) If Host died with disablesleep still on, clear it.
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
"""#

    static let install = #"""
#!/bin/bash
# Installs passwordless pmset for lid-closed stay-awake and a LaunchAgent watchdog.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="$(/usr/bin/id -un)"
USER_ID="$(/usr/bin/id -u)"
SUPPORT_DIR="${HOME}/Library/Application Support/Tether"
AGENT_DIR="${HOME}/Library/LaunchAgents"
AGENT_LABEL="com.tether.host.sleep-recovery"
AGENT_PLIST="${AGENT_DIR}/${AGENT_LABEL}.plist"
RECOVERY_SRC="${SCRIPT_DIR}/tether-sleep-recovery.sh"
RECOVERY_DST="${SUPPORT_DIR}/tether-sleep-recovery.sh"
REQUEST_PATH="${SUPPORT_DIR}/sleep-control.request"
SUDOERS_PATH="/etc/sudoers.d/tether-sleep"

echo ""
echo "Tether — lid-closed awake"
echo ""
echo "Installs a privilege rule, a helper script, and a LaunchAgent"
echo "so Host can keep the Mac awake with the lid closed."
echo ""
echo "Enter your Mac login password when asked."
echo ""

/usr/bin/sudo -k
if ! /usr/bin/sudo -v; then
  echo "Cancelled." >&2
  exit 1
fi

/bin/mkdir -p "${SUPPORT_DIR}"
/bin/chmod 700 "${SUPPORT_DIR}"
/bin/cp "${RECOVERY_SRC}" "${RECOVERY_DST}"
/bin/chmod 700 "${RECOVERY_DST}"

/bin/mkdir -p "${AGENT_DIR}"
/bin/cat > "${AGENT_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${AGENT_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>${RECOVERY_DST}</string>
	</array>
	<key>WatchPaths</key>
	<array>
		<string>${REQUEST_PATH}</string>
	</array>
	<key>StartInterval</key>
	<integer>60</integer>
	<key>ThrottleInterval</key>
	<integer>1</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>/tmp/tether-sleep-recovery.log</string>
	<key>StandardErrorPath</key>
	<string>/tmp/tether-sleep-recovery.log</string>
</dict>
</plist>
EOF
/bin/chmod 644 "${AGENT_PLIST}"

# Files created via Terminal-from-app can carry quarantine; launchd rejects those.
/usr/bin/xattr -cr "${SUPPORT_DIR}" 2>/dev/null || true
/usr/bin/xattr -cr "${AGENT_PLIST}" 2>/dev/null || true
/usr/bin/xattr -d com.apple.quarantine "${AGENT_PLIST}" 2>/dev/null || true
/usr/bin/xattr -d com.apple.quarantine "${RECOVERY_DST}" 2>/dev/null || true

TMP_SUDOERS="$(/usr/bin/mktemp)"
/bin/cat > "${TMP_SUDOERS}" <<EOF
${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/pmset
EOF
/bin/chmod 440 "${TMP_SUDOERS}"

if ! /usr/sbin/visudo -cf "${TMP_SUDOERS}" >/dev/null; then
  echo "Privilege rule failed validation." >&2
  /bin/rm -f "${TMP_SUDOERS}"
  exit 1
fi

echo "• Privilege rule"
/usr/bin/sudo /bin/cp "${TMP_SUDOERS}" "${SUDOERS_PATH}"
/usr/bin/sudo /bin/chmod 440 "${SUDOERS_PATH}"
/bin/rm -f "${TMP_SUDOERS}"

/usr/bin/sudo -k
/bin/rm -f "${SUPPORT_DIR}/sleep-control.result" /tmp/tether-sleep-recovery.log
printf '0\n' > "${REQUEST_PATH}"
if ! /bin/bash "${RECOVERY_DST}" || ! grep -q '^ok' "${SUPPORT_DIR}/sleep-control.result" 2>/dev/null; then
  echo "Privilege rule is installed but pmset still needs a password." >&2
  exit 1
fi
/bin/rm -f "${SUPPORT_DIR}/sleep-control.result"

echo "• Helper script"
echo "• LaunchAgent"
launchctl bootout "gui/${USER_ID}/${AGENT_LABEL}" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if ! launchctl print "gui/${USER_ID}/${AGENT_LABEL}" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.1
done

bootstrap_ok=0
if launchctl bootstrap "gui/${USER_ID}" "${AGENT_PLIST}"; then
  bootstrap_ok=1
else
  /usr/bin/xattr -cr "${AGENT_PLIST}" 2>/dev/null || true
  /usr/bin/xattr -cr "${SUPPORT_DIR}" 2>/dev/null || true
  /bin/sleep 0.3
  if launchctl bootstrap "gui/${USER_ID}" "${AGENT_PLIST}"; then
    bootstrap_ok=1
  fi
fi
if [[ "${bootstrap_ok}" -ne 1 ]]; then
  echo "Could not load the LaunchAgent." >&2
  exit 1
fi
launchctl enable "gui/${USER_ID}/${AGENT_LABEL}" 2>/dev/null || true

if ! launchctl print "gui/${USER_ID}/${AGENT_LABEL}" >/dev/null 2>&1; then
  echo "LaunchAgent did not stay loaded." >&2
  exit 1
fi

/bin/rm -f "${SUPPORT_DIR}/sleep-control.result"
printf '0\n' > "${REQUEST_PATH}"
/bin/sleep 0.2
launchctl kickstart -k "gui/${USER_ID}/${AGENT_LABEL}" 2>/dev/null || true
ok=0
for _ in $(seq 1 50); do
  if [[ -f "${SUPPORT_DIR}/sleep-control.result" ]] && grep -q '^ok' "${SUPPORT_DIR}/sleep-control.result"; then
    ok=1
    break
  fi
  /bin/sleep 0.1
done
/bin/rm -f "${SUPPORT_DIR}/sleep-control.result" "${REQUEST_PATH}"
if [[ "${ok}" -ne 1 ]]; then
  echo "LaunchAgent loaded but did not apply a sleep change." >&2
  exit 1
fi

printf 'installed\n' > "${SUPPORT_DIR}/sleep-privilege.installed"
/bin/chmod 600 "${SUPPORT_DIR}/sleep-privilege.installed"
: > /tmp/tether-sleep-recovery.log

echo ""
echo "Done."
echo "Return to Tether → Lid-closed awake → Recheck."
echo "Turn Prevent sleep on; Right now should say Holding awake."
echo ""
"""#

    static let uninstall = #"""
#!/bin/bash
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
"""#
}
