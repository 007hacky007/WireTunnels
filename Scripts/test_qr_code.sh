#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="$ROOT_DIR/WireTunnels/Services/QRCodeService.swift"
DETAIL="$ROOT_DIR/WireTunnels/Views/Dashboard/TunnelDetailView.swift"
IMPORT="$ROOT_DIR/WireTunnels/Views/Config/ImportConfigView.swift"

test -f "$SERVICE" ||
    { echo "QRCodeService.swift must exist" >&2; exit 1; }
grep -q 'static func generate(from text: String) -> NSImage?' "$SERVICE" ||
    { echo "QRCodeService must expose generate(from:)" >&2; exit 1; }
grep -q 'static func decode(from image: NSImage) -> String?' "$SERVICE" ||
    { echo "QRCodeService must expose decode(from:)" >&2; exit 1; }

grep -q 'Label("Show QR Code", systemImage: "qrcode")' "$DETAIL" ||
    { echo "TunnelDetailView must offer a Show QR Code action" >&2; exit 1; }
# The QR button must live inside the `if !isManaged` branch of actionsSection —
# managed tunnels must never expose their (shared, root-owned) private key via QR.
awk '/private var actionsSection: some View \{/,/^    \}$/' "$DETAIL" > /tmp/wiretunnels_actions.$$
awk '/if !isManaged \{/,0' /tmp/wiretunnels_actions.$$ | grep -q 'Show QR Code' ||
    { echo "QR export must be gated inside the personal-tunnel (!isManaged) branch" >&2; exit 1; }
rm -f /tmp/wiretunnels_actions.$$
grep -q 'private struct QRCodeSheetView' "$DETAIL" ||
    { echo "TunnelDetailView must define a QR code sheet view" >&2; exit 1; }
grep -q 'private key' "$DETAIL" ||
    { echo "The QR code sheet must warn that it contains the private key" >&2; exit 1; }

grep -q 'func pasteFromClipboard()' "$IMPORT" ||
    { echo "ImportConfigView must support pasting a QR code from the clipboard" >&2; exit 1; }
grep -q 'func handleQRImage(_ image: NSImage)' "$IMPORT" ||
    { echo "ImportConfigView must decode QR images through a shared helper" >&2; exit 1; }
grep -q 'performImport()' "$IMPORT" &&
grep -c 'performImport()' "$IMPORT" | grep -qv '^0$' ||
    { echo "QR import must reuse performImport() rather than a separate import path" >&2; exit 1; }
grep -q 'QRCodeService.decode' "$IMPORT" ||
    { echo "ImportConfigView must call QRCodeService.decode" >&2; exit 1; }

echo "QR code checks passed"
