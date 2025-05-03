#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_DIR_NAME=$(basename "$SCRIPT_DIR")
ICON_PATH="${SCRIPT_DIR}/data/flutter_assets/assets/images/rad_logo.png"
WRAPPER_SCRIPT_NAME="start-radcxp"
WRAPPER_SCRIPT_PATH="${SCRIPT_DIR}/${WRAPPER_SCRIPT_NAME}"
DESKTOP_ENTRY_NAME="radcxp.desktop"
AUTOSTART_DIR="${HOME}/.config/autostart"

echo "--- Remote Assist Display CXP Installer ---"

if [ "$APP_DIR_NAME" != "remote_assist_display_cxp" ]; then
  echo "[Error] Please run this script from within the 'remote_assist_display_cxp' directory."
  exit 1
fi

echo "[Step 1/3] Making 'radcxp' binary executable..."
if chmod +x "${SCRIPT_DIR}/radcxp"; then
  echo "  Success."
else
  echo "  [Error] Failed to make 'radcxp' executable. Please check permissions."
  exit 1
fi

echo "[Step 2/3] Creating startup wrapper script ('${WRAPPER_SCRIPT_NAME}')..."

IS_PMOS=false
if uname -a | grep -q "postmarketos"; then
  IS_PMOS=true
  echo "  Detected postmarketOS. Applying specific environment variables."
fi

cat > "${WRAPPER_SCRIPT_PATH}" << EOF
#!/bin/bash
# Wrapper script for Remote Assist Display CXP

WRAPPER_DIR="\$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

export LD_LIBRARY_PATH="\${WRAPPER_DIR}/lib:\$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="\$LD_LIBRARY_PATH:/usr/lib"

# Apply postmarketOS specific settings if detected by installer
$(if [ "$IS_PMOS" = true ]; then echo "export MESA_GLES_VERSION_OVERRIDE=2.0"; else echo "# export MESA_GLES_VERSION_OVERRIDE=2.0 # (Uncomment if needed)"; fi)
$(if [ "$IS_PMOS" = true ]; then echo "export WEBKIT_DISABLE_COMPOSITING_MODE=1"; else echo "# export WEBKIT_DISABLE_COMPOSITING_MODE=1 # (Uncomment if needed)"; fi)

cd "\${WRAPPER_DIR}" && ./radcxp
EOF

if chmod +x "${WRAPPER_SCRIPT_PATH}"; then
  echo "  Successfully created and made '${WRAPPER_SCRIPT_NAME}' executable."
else
  echo "  [Error] Failed to make '${WRAPPER_SCRIPT_NAME}' executable. Please check permissions."
  rm -f "${WRAPPER_SCRIPT_PATH}"
  exit 1
fi

echo "[Step 3/3] Configure Autostart (Optional)"
read -p "  Do you want Remote Assist Display to start automatically on login? (y/N): " choice
case "$choice" in
  y|Y )
    echo "  Setting up autostart..."
    mkdir -p "${AUTOSTART_DIR}"
    if [ $? -ne 0 ]; then
      echo "    [Error] Could not create autostart directory: ${AUTOSTART_DIR}"
      echo "    Skipping autostart setup."
    else
      echo "    Creating desktop entry: ${AUTOSTART_DIR}/${DESKTOP_ENTRY_NAME}"
      cat > "${AUTOSTART_DIR}/${DESKTOP_ENTRY_NAME}" << EOF
[Desktop Entry]
Name=RemoteAssistDisplay
Comment=Remote Assist Display Companion App
Exec=${WRAPPER_SCRIPT_PATH}
Icon=${ICON_PATH}
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
X-GNOME-AutoRestart=true
EOF
      if [ $? -eq 0 ]; then
        echo "    Autostart configured successfully."
      else
        echo "    [Error] Failed to create desktop entry file."
      fi
    fi
    ;;
  * )
    echo "  Skipping autostart configuration."
    ;;
esac

echo ""
echo "--- Installation Complete ---"
echo "You can now run the application manually by executing:"
echo "  ${WRAPPER_SCRIPT_PATH}"
echo ""
$(if [ "$IS_PMOS" = true ]; then
  echo "NOTE for postmarketOS users running via SSH:"
  echo "  If the application doesn't appear on the device display when run manually,"
  echo "  you might need to set the XDG runtime directory before running the script:"
  echo "  export XDG_RUNTIME_DIR=\"/run/user/10000\" # (Adjust user ID if needed)"
  echo "  Then run: ${WRAPPER_SCRIPT_PATH}"
  echo ""
fi)
echo "If you enabled autostart, it should launch the next time you log in."
echo "To uninstall, simply delete the application directory ('${SCRIPT_DIR}')"
echo "and remove the desktop entry file if you created it:"
echo "  rm -f '${AUTOSTART_DIR}/${DESKTOP_ENTRY_NAME}'"
echo "-----------------------------"

exit 0
