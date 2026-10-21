#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/WireTunnels.xcodeproj/project.pbxproj"
SERVICE="$ROOT_DIR/WireTunnels/Services/WireGuardCommandService.swift"

if ! grep -q '"$(SRCROOT)/WireTunnelsHelper/com.fmdigitech.WireTunnels.helper.plist"' "$PROJECT"; then
    echo "Helper plist must be a declared build-phase input" >&2
    exit 1
fi

if ! grep -q '"$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchDaemons/com.fmdigitech.WireTunnels.helper.plist"' "$PROJECT"; then
    echo "Packaged helper plist must be a declared build-phase output" >&2
    exit 1
fi

if grep -q 'error.code == 1' "$SERVICE"; then
    echo "SMAppService error code 1 must not be treated as successful registration" >&2
    exit 1
fi

if ! grep -q 'func installHelper(replacingExisting: Bool = false) async throws' "$SERVICE"; then
    echo "Helper replacement must await asynchronous unregistration" >&2
    exit 1
fi

if ! grep -q 'daemonService.unregister { error in' "$SERVICE"; then
    echo "Helper replacement must use the unregister completion handler" >&2
    exit 1
fi

echo "Helper registration build inputs and errors are configured correctly"
