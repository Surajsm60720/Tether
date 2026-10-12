#!/bin/bash
# Keep in sync with TetherHost/SleepPrivilegeScripts.swift
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
