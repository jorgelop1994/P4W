#!/usr/bin/env bash
# Arma el .dmg de P4W: compila universal, ensambla la app y la mete en un disco de sólo lectura.
#
# El `.dmg` es lo que hace que la app llegue a otra Mac. Se hace con `hdiutil`, que es la herramienta de
# macOS: no hay motivo para escribir un formato de disco a mano.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep -o 'current = "[0-9.]*"' Sources/P4WCore/Version.swift | grep -o '[0-9.]*' | head -1)"
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

# Notariza un artefacto y devuelve si Apple lo aceptó.
#
# Sin cañería a propósito: `comando | grep -q patrón` con `set -o pipefail` da un falso negativo, porque
# `grep -q` corta apenas encuentra, el otro proceso muere por el corte y el resultado se reporta como fallo.
# Pasó: el registro de Apple decía «Accepted» y el script decía que no.
notarize() {
  local path="$1" out
  out="$(xcrun notarytool submit "$path" --keychain-profile "$PROFILE" --wait 2>&1 || true)"
  case "$out" in
    *"status: Accepted"*) return 0 ;;
    *) echo "$out" | tail -3 | sed 's/^/     /'; return 1 ;;
  esac
}

if [[ -n "$DEVELOPER_ID" ]] && xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "→ notarizando (perfil: $PROFILE)"

  # El orden importa, y la primera versión de esto lo tenía mal: se engrapaba la app **antes** de
  # notarizar, cuando el ticket todavía no existe, y el fallo quedaba tapado por un `|| true`. La app se
  # publicaba sin su ticket (abre igual con internet, porque Gatekeeper consulta el registro de Apple).
  #
  # El orden correcto es: notarizar la app, engrapársela, y **después** armar el disco con esa app adentro.
  # Así la app abre aunque la copien a una máquina sin conexión, y el disco también.
  ZIP="$(mktemp -d)/P4W.zip"
  ditto -c -k --sequesterRsrc --keepParent dist/P4W.app "$ZIP"
  if notarize "$ZIP"; then
    if [[ "$(xcrun stapler staple dist/P4W.app 2>&1 || true)" == *worked* ]]; then
      echo "  ✓ app notarizada y con el ticket engrapado"
    else
      echo "  ✗ la app no se pudo engrapar: el disco sirve, pero no sin conexión"
    fi
    # El disco se rehace **desde la app ya sellada**. Y si falla, se dice: la primera versión de este bloque
    # reconstruía el disco desde un directorio que ya se había borrado, `hdiutil` fallaba en silencio y el
    # disco salía con la app sin ticket. Se publicó una versión así.
    rm -f "$DMG"
    if hdiutil create -volname "P4W" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1; then
      echo "  ✓ disco rearmado, con la app sellada adentro"
    else
      echo "  ✗ no se pudo rearmar el disco: se publica el anterior, con la app sin ticket"
    fi
    if notarize "$DMG"; then
      if [[ "$(xcrun stapler staple "$DMG" 2>&1 || true)" == *worked* ]]; then
        echo "  ✓ disco notarizado y engrapado"
      else
        echo "  ✗ el disco se notarizó pero no se pudo engrapar"
      fi
    else
      echo "  ⚠️ el disco no llegó a Accepted (la app sí: se puede distribuir igual)"
    fi
  else
    echo "  ✗ la notarización de la app no fue aceptada"
  fi

  rm -rf "$STAGE"

  # La comprobación que vale es **sobre la app**, no sobre el disco: `spctl --type open` sobre un `.dmg`
  # devuelve "rejected" aunque el disco esté notarizado y engrapado (pasó, y dio una falsa alarma).
  xcrun stapler validate dist/P4W.app >/dev/null 2>&1 && echo "  ✓ el ticket de la app valida"
  spctl --assess --type execute dist/P4W.app 2>/dev/null \
    && echo "  ✓ Gatekeeper acepta la app" || echo "  ⚠️ Gatekeeper no acepta la app"
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
