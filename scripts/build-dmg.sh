#!/usr/bin/env bash
# Arma el .dmg de P4W: compila universal, ensambla la app y la mete en un disco de sólo lectura.
#
# El `.dmg` es lo que hace que la app llegue a otra Mac. Se hace con `hdiutil`, que es la herramienta de
# macOS: no hay motivo para escribir un formato de disco a mano.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep -m1 CFBundleShortVersionString -A1 scripts/build-app.sh | grep -o '[0-9.]*' | head -1 || echo 0.1.0)"
STAGE="dist/dmg-stage"
DMG="dist/P4W-$VERSION.dmg"

echo "→ compilando universal"
swift build -c release --arch arm64 --arch x86_64 >/dev/null

echo "→ ensamblando la app"
scripts/build-app.sh --universal >/dev/null

echo "→ armando el disco"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R dist/P4W.app "$STAGE/P4W.app"
# El atajo a Aplicaciones es lo que hace que arrastrar la app sea el gesto obvio.
ln -s /Applications "$STAGE/Applications"

# `diskutil image` y no `hdiutil`: las tres operaciones que se usan acá están deprecadas en `hdiutil`
# (el propio sistema lo avisa al correrlas). Si la herramienta nueva no está, se cae a la vieja.
if diskutil image create from /dev/null /dev/null >/dev/null 2>&1 || diskutil image create --help >/dev/null 2>&1; then
  diskutil image create from "$STAGE" "$DMG" --format UDZO --volumeName "P4W" >/dev/null
else
  echo "  (diskutil image no está; se usa hdiutil)"
  hdiutil create -volname "P4W" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi
rm -rf "$STAGE"

echo "→ verificando el disco"
# El disco se monta de verdad y se mira adentro: que el atajo esté y que el bundle tenga el ícono. Un
# `.dmg` que "verifica" pero no monta no sirve para nada.
MOUNT="$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null | grep -o '/Volumes/.*' | head -1)"
if [[ -n "$MOUNT" ]]; then
  [[ -L "$MOUNT/Applications" ]] && echo "  ✓ con el atajo a Aplicaciones"
  [[ -f "$MOUNT/P4W.app/Contents/Resources/P4W.icns" ]] && echo "  ✓ con el ícono adentro"
  [[ -x "$MOUNT/P4W.app/Contents/MacOS/P4W" ]] && echo "  ✓ con la app ejecutable"
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
else
  echo "  ✗ el disco no se pudo montar"; exit 1
fi

SIZE="$(du -h "$DMG" | cut -f1)"
# ── Notarización ──────────────────────────────────────────────────────────────────────────────────
# Se hace **solo si se puede**: hace falta una identidad de Developer ID y un perfil de credenciales en el
# llavero (`xcrun notarytool store-credentials p4w`). Sin eso, el disco se arma igual y el README explica el
# clic derecho → Abrir. Un `.dmg` sin notarizar no es un error: es una versión que funciona con un paso más
# la primera vez.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
PROFILE="${P4W_NOTARY_PROFILE:-p4w}"

if [[ -n "$DEVELOPER_ID" ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "→ notarizando (perfil: $PROFILE)"
  # Se engrapa el ticket en la app **antes** de armar el disco, y después en el disco: así la app abra
  # aunque el disco se copie sin conexión, y el disco abra aunque la app se copie sin conexión.
  xcrun stapler staple dist/P4W.app >/dev/null 2>&1 || true
  if xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | grep -q "status: Accepted"; then
    xcrun stapler staple "$DMG" >/dev/null 2>&1 || true
    echo "  ✓ notarizado y engrapado"
  else
    echo "  ✗ la notarización no fue aceptada (el disco queda sin notarizar)"
  fi
  spctl --assess --type open --context context:primary-signature "$DMG" >/dev/null 2>&1 \
    && echo "  ✓ Gatekeeper lo acepta" || echo "  ⚠️ Gatekeeper todavía no lo acepta"
elif [[ -n "$DEVELOPER_ID" ]]; then
  echo "  (hay Developer ID pero no hay perfil de notarización: corré"
  echo "     xcrun notarytool store-credentials $PROFILE --apple-id TU_APPLE_ID --team-id TU_TEAM_ID"
  echo "   y sacá el Team ID de acá — es el campo organizationalUnitName, y **no** el número"
  echo "   entre paréntesis del nombre del certificado, que es el identificador del certificado:"
  echo "     security find-certificate -c \"Apple Development\" -p | openssl x509 -noout -subject -nameopt multiline)"
else
  echo "  (sin Developer ID: el disco va sin notarizar — el README explica el clic derecho → Abrir)"
fi

echo "→ arquitecturas: $(lipo -archs dist/P4W.app/Contents/MacOS/P4W)"
echo "✓ listo: $DMG ($SIZE)"
