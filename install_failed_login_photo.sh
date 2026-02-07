#!/usr/bin/env bash
clear
#-----------------------------------------------
# (C)opyleft Keld Norman, Jun 2025
#
# Script to monitor the system for failed login
# attempts and take a photo if it occurs
#-----------------------------------------------
set -euo pipefail
#-----------------------------------------------
# Variables
#-----------------------------------------------
PHOTO_OWNER="norman"
PHOTO_GROUP="norman"
PHOTO_DEV="/dev/video0"
PHOTO_DIR="/home/norman/failed-logins"
MONITOR_SCRIPT="/usr/local/bin/failed-login-monitor.sh"
SYSTEMD_SERVICE="/etc/systemd/system/failed-login-photo.service"
#-----------------------------------------------
# Root Check
#-----------------------------------------------
if [[ $EUID -ne 0 ]]; then
 printf "\n[!] Error: This script must be run as root or with sudo.\n\n"
 exit 1
fi
#-----------------------------------------------
# Uninstall Logic
#-----------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
 if [ ! -f "$SYSTEMD_SERVICE" ] && [ ! -f "$MONITOR_SCRIPT" ]; then
  printf "\n[!] Login script was not installed !\n\n"
  exit 0
 fi
 printf "\n[*] Uninstalling Failed Login Photo Service...\n\n"
 if systemctl is-active --quiet failed-login-photo.service; then
  systemctl stop failed-login-photo.service >/dev/null 2>&1 || true
 fi
 systemctl disable failed-login-photo.service >/dev/null 2>&1 || true
 [ -f "$SYSTEMD_SERVICE" ] && rm -f "$SYSTEMD_SERVICE"
 [ -f "$MONITOR_SCRIPT" ] && rm -f "$MONITOR_SCRIPT"
 systemctl daemon-reload >/dev/null 2>&1
 exit 0
fi
#-----------------------------------------------
# Check if already installed
#-----------------------------------------------
if [ -f "$SYSTEMD_SERVICE" ]; then
 printf "\n[!] Login Photo Service already installed.\n\n"
 exit 1
fi
#-----------------------------------------------
# Check Owner User exists
#-----------------------------------------------
if ! id "$PHOTO_OWNER" >/dev/null 2>&1; then
 printf "\n[!] Error: User '%s' does not exist. Please create user or adjust variables.\n\n" "$PHOTO_OWNER"
 exit 1
fi
#-----------------------------------------------
# Install Dependencies
#-----------------------------------------------
MISSING_PKGS=()
for pkg in ffmpeg coreutils; do
 if ! command -v "$pkg" >/dev/null 2>&1 && [ "$pkg" != "coreutils" ]; then
  MISSING_PKGS+=("$pkg")
 elif [ "$pkg" == "coreutils" ] && ! command -v timeout >/dev/null 2>&1; then
  MISSING_PKGS+=("coreutils")
 fi
done
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
 printf "[*] Installing dependencies: %s\n" "${MISSING_PKGS[*]}"
 apt-get update -qq && apt-get install -qq -y "${MISSING_PKGS[@]}"
fi
#-----------------------------------------------
# 1. Create the Monitor Script
#-----------------------------------------------
printf "\n[*] Creating monitor script:  %s\n" "${MONITOR_SCRIPT}"
cat <<EOF > "${MONITOR_SCRIPT}"
#!/bin/bash
# Configuration
PHOTO_OWNER="${PHOTO_OWNER}"
PHOTO_GROUP="${PHOTO_GROUP}"
PHOTO_DEV="${PHOTO_DEV}"
PHOTO_DIR="${PHOTO_DIR}"
LOG_PATTERN="authentication failure"
# Ensure directory exists with correct permissions
if [ ! -d "\${PHOTO_DIR}" ]; then
 mkdir -m 750 -p "\${PHOTO_DIR}"
fi
# Enforce ownership on directory (in case it was created by root previously)
chown "\${PHOTO_OWNER}:\${PHOTO_GROUP}" "\${PHOTO_DIR}"
printf "[*] Starting Log Monitor for pattern: '\${LOG_PATTERN}'\n"
journalctl -f -n 0 -q | while read -r line; do
 # Check if line contains the failure pattern
 if echo "\$line" | grep -q "\${LOG_PATTERN}"; then
  # Debounce logic
  LAST_PHOTO=\$(ls -t "\${PHOTO_DIR}"/*.jpg 2>/dev/null | head -n 1)
  if [ -n "\$LAST_PHOTO" ]; then
   LAST_TIME=\$(stat -c %Y "\$LAST_PHOTO")
   NOW=\$(date +%s)
   DIFF=\$((NOW - LAST_TIME))
   if [ \$DIFF -lt 4 ]; then
    continue
   fi
  fi
  TIMESTAMP=\$(date +'%Y-%m-%d_%H-%M-%S')
  FILENAME="failed-login_\${TIMESTAMP}.jpg"
  FULL_PATH="\${PHOTO_DIR}/\${FILENAME}"
  # Take the photo
  /usr/bin/timeout 5s /usr/bin/ffmpeg -y -f video4linux2 -i "\${PHOTO_DEV}" -frames:v 1 "\${FULL_PATH}" -loglevel quiet
  # Set ownership and permissions if file was created
  if [ -f "\${FULL_PATH}" ]; then
   chown "\${PHOTO_OWNER}:\${PHOTO_GROUP}" "\${FULL_PATH}"
   chmod 400 "\${FULL_PATH}"
   echo "Failed login detected! Photo saved: \${FILENAME}"
  fi
 fi
done
EOF
chmod 700 "${MONITOR_SCRIPT}"
chown root:root "${MONITOR_SCRIPT}"
#-----------------------------------------------
# 2. Create Systemd Service
#-----------------------------------------------
printf "[*] Creating Systemd service: %s\n" "${SYSTEMD_SERVICE}"
cat <<EOF > "${SYSTEMD_SERVICE}"
[Unit]
Description=Failed Login Photo Monitor
After=network.target syslog.service

[Service]
Type=simple
ExecStart=${MONITOR_SCRIPT}
Restart=always
RestartSec=3
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF
#-----------------------------------------------
# 3. Enable and Start Service
#-----------------------------------------------
systemctl daemon-reload
systemctl enable failed-login-photo.service >/dev/null 2>&1
systemctl restart failed-login-photo.service
#-----------------------------------------------
# Validation
#-----------------------------------------------
sleep 2
if ! systemctl is-active --quiet failed-login-photo.service; then
 printf "[!] Service failed to start. Check: systemctl status failed-login-photo.service\n"
 exit 1
fi
if [ ! -c "$PHOTO_DEV" ]; then
 printf "[!] WARNING: Camera device %s not found. Service is running but will not capture images.\n" "$PHOTO_DEV"
fi
printf "[*] Photos will be saved in:  %s\n" "${PHOTO_DIR}"
printf "[*] Ownership set to:         %s:%s\n\n" "${PHOTO_OWNER}" "${PHOTO_GROUP}"
#-----------------------------------------------
# End of script
#-----------------------------------------------
