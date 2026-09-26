#!/bin/bash
# Ensambla P4W.app alrededor del ejecutable de SwiftPM.
#
# Una app GUI en macOS necesita un bundle real: sin Info.plist no obtiene identificador,
# no aparece bien en el Dock, y las notificaciones no se pueden registrar.
#
# Uso:
#   scripts/build-app.sh              # arquitectura nativa (rápido)
#   scripts/build-app.sh --universal  # arm64 + x86_64 (el binario que va a su Mac)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/P4W.app"
UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

if [[ $UNIVERSAL -eq 1 ]]; then
  echo "→ compilando universal (arm64 + x86_64)…"
  swift build -c release --arch arm64 --arch x86_64
  BIN="$ROOT/.build/out/Products/Release/P4W"
else
  echo "→ compilando arquitectura nativa…"
  swift build -c release
  BIN="$ROOT/.build/release/P4W"
fi

[[ -x "$BIN" ]] || { echo "✗ no encontré el binario en $BIN"; exit 1; }

echo "→ ensamblando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/P4W"

# El ícono se genera desde el mismo pipeline que el gato (la grilla de píxeles), no es un binario suelto
# en el repo. Se genera solo si falta: `--render-icon` es el que lo rehace.
if [[ ! -f dist/icon/P4W.icns ]]; then
  echo "→ generando el ícono del gato"
  (cd "$ROOT" && "$BIN" --render-icon >/dev/null 2>&1) || echo "  (no se pudo generar el ícono)"
fi
[[ -f dist/icon/P4W.icns ]] && cp dist/icon/P4W.icns "$APP/Contents/Resources/P4W.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>P4W</string>
    <key>CFBundleDisplayName</key>          <string>P4W</string>
    <key>CFBundleExecutable</key>           <string>P4W</string>
    <key>CFBundleIdentifier</key>           <string>dev.p4w.app</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>P4W</string>
    <key>CFBundleShortVersionString</key>   <string>0.1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>15.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# Firma ad-hoc: alcanza para correr localmente y para que macOS trate la app como app.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (sin firma; se puede correr igual)"

echo "→ ícono:         $([[ -f "$APP/Contents/Resources/P4W.icns" ]] && echo sí || echo no)"
echo "→ arquitecturas: $(lipo -archs "$APP/Contents/MacOS/P4W")"
echo "→ minos:         $(vtool -show-build "$APP/Contents/MacOS/P4W" 2>/dev/null | grep -m1 minos | awk '{print $2}')"
echo "✓ listo: $APP"
echo "  abrir con:  open \"$APP\""
