#!/usr/bin/env bash
# Assembles the PUBLIC repository for P4W, auditing it before anything leaves this machine.
#
# Why a script instead of just pushing this repository: this working tree is also the project's journal.
# It contains PLAN.md, STATUS.md, LOOP.md and WISHLIST.md — 160 KB of Spanish notes with measurements,
# private decisions, and references to machines that are not mine to publish. On top of that, an older
# commit still contains a personal home path, and **a secret or a path in history stays in history even
# after you delete the file**.
#
# So the public tree is *built*, never hand-maintained, and every build is audited. If the audit finds
# something, nothing is published.
#
# Usage:
#   scripts/publish.sh                     # assemble + audit into ../P4W-public (no network)
#   scripts/publish.sh --to /some/dir      # somewhere else
#   scripts/publish.sh --push              # also create the GitHub repo and push (public!)
#   scripts/publish.sh --release           # also build the .dmg, tag, and create the release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO="jorgelop1994/P4W"
TARGET="$ROOT/../P4W-public"
PUSH=0
RELEASE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TARGET="$2"; shift 2 ;;
    --push) PUSH=1; shift ;;
    --release) RELEASE=1; PUSH=1; shift ;;
    *) echo "no entiendo «$1»"; exit 2 ;;
  esac
done

VERSION="$(grep -o 'current = "[0-9.]*"' Sources/P4WCore/Version.swift | grep -o '[0-9.]*' | head -1)"
[[ -n "$VERSION" ]] || { echo "✗ no pude leer la versión de scripts/build-app.sh"; exit 1; }

# Allowlist, not a denylist: what is not listed here does not get published, and a new file has to be
# added on purpose. A denylist fails open the day someone adds a file; an allowlist fails closed.
PUBLIC=(
  Sources
  Package.swift
  README.md
  LICENSE
  CHANGELOG.md
  .gitignore
  .github
  docs
  fixtures
  scripts/build-app.sh
  scripts/build-dmg.sh
  scripts/publish.sh
)

echo "→ armando el árbol público en $TARGET (v$VERSION)"
mkdir -p "$TARGET"
# The tree is rebuilt from scratch every time, keeping only the public history. Copying over what is
# already there is not enough: a file deleted here — or one deleted *because it had a secret* — would sit
# in the public tree forever. Rebuilding makes "what is published" equal to "what is in the allowlist",
# with no room for drift.
find "$TARGET" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
for item in "${PUBLIC[@]}"; do
  [[ -e "$item" ]] || { echo "✗ falta «$item» en el repo de trabajo"; exit 1; }
  # Con su carpeta: `cp -R archivo destino/` deja el archivo suelto en la raíz, y `scripts/build-app.sh`
  # terminaba como `/build-app.sh`. Se copia al directorio que le corresponde.
  mkdir -p "$TARGET/$(dirname "$item")"
  cp -R "$item" "$TARGET/$(dirname "$item")/"
done

# ── Auditoría ─────────────────────────────────────────────────────────────────────────────────────
# Three things can go wrong here, and all of them are worth stopping for.
echo "→ auditando"
PROBLEMS=0
fail() { echo "  ✗ $1"; PROBLEMS=$((PROBLEMS + 1)); }

# 1. The journal must never reach the public repo.
for secret_doc in PLAN.md STATUS.md LOOP.md WISHLIST.md; do
  [[ -e "$TARGET/$secret_doc" ]] && fail "el diario ($secret_doc) llegó al árbol público"
done

# 2. No personal home paths. They look harmless and they are not: they carry a username.
HOMES="$(grep -rIl --exclude-dir=.git -E '/Users/[A-Za-z0-9._-]+' "$TARGET" 2>/dev/null || true)"
[[ -n "$HOMES" ]] && fail "rutas personales en: $(echo "$HOMES" | tr '\n' ' ')"

# 3. No credentials. Nothing in this project should ever contain one, and the day it does, it will not
#    be published by accident.
# El propio script queda afuera del escaneo, y por un motivo concreto: los patrones que busca están
# escritos en él, así que se encuentra a sí mismo. Es la única exclusión, y está dicha.
SECRETS="$(grep -rIl --exclude-dir=.git --exclude=publish.sh -E \
  'sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[A-Z0-9]{12,}|xoxb-|BEGIN [A-Z ]*PRIVATE KEY|api[_-]?key[[:space:]]*=[[:space:]]*"[^"]{8,}"' \
  "$TARGET" 2>/dev/null || true)"
[[ -n "$SECRETS" ]] && fail "posibles credenciales en: $(echo "$SECRETS" | tr '\n' ' ')"

# 4. Build output and data have no business here.
[[ -d "$TARGET/dist" || -d "$TARGET/.build" ]] && fail "hay salida de compilación (dist/ o .build/)"
FOUND_DATA="$(find "$TARGET" ! -path '*/.git/*' \( -name '*.dmg' -o -name '*.app' -o -name '*.jsonl' \
  -o -name '*.db' -o -name '*.sqlite*' -o -name 'settings.json' -o -name 'auth.json' \) 2>/dev/null || true)"
[[ -n "$FOUND_DATA" ]] && fail "hay datos o binarios de salida: $(echo "$FOUND_DATA" | tr '\n' ' ')"

# 5. Nothing absurdly large: the repo has to stay cloneable.
BIG="$(find "$TARGET" ! -path '*/.git/*' -type f -size +2M 2>/dev/null || true)"
[[ -n "$BIG" ]] && fail "archivos de más de 2 MB: $(echo "$BIG" | tr '\n' ' ')"

if [[ "$PROBLEMS" -gt 0 ]]; then
  echo "✗ la auditoría encontró $PROBLEMS problema(s): NO se publica nada."
  exit 1
fi

COUNT="$(find "$TARGET" ! -path '*/.git/*' -type f | wc -l | tr -d ' ')"
SIZE="$(du -sh "$TARGET" 2>/dev/null | cut -f1)"
SWIFT_FILES="$(find "$TARGET" -name '*.swift' | wc -l | tr -d ' ')"
LOC="$(find "$TARGET" -name '*.swift' -exec cat {} + | wc -l | tr -d ' ')"
echo "  ✓ sin diario · sin rutas personales · sin credenciales · sin binarios · sin archivos grandes"
echo "  $COUNT archivos ($SWIFT_FILES de Swift, $LOC líneas) · $SIZE"

# ── Historial ─────────────────────────────────────────────────────────────────────────────────────
# Fresh history on purpose. This project's private history contains the journal and that personal path;
# rewriting it is fragile and keeping it publishes things that were never meant to be public. A first
# public commit is the cleanest thing that can be said about it.
if [[ ! -d "$TARGET/.git" ]]; then
  echo "→ empezando un historial público nuevo"
  git -C "$TARGET" init -q -b main
fi

# El correo del commit, **siempre el noreply de GitHub**.
#
# GitHub muestra el autor de cada commit a cualquiera, y el correo de la configuración de la máquina es el
# personal: publicar así deja el Gmail a la vista, y hay gente que cosecha correos de repos públicos. El
# noreply lo ata igual a la cuenta —el commit aparece como tuyo— sin publicar la dirección.
#
# Se pone acá y no en la configuración global para no tocar el resto de los repos de la máquina.
if [[ -n "${GITHUB_NOREPLY:-}" ]]; then
  git -C "$TARGET" config user.email "$GITHUB_NOREPLY"
  git -C "$TARGET" config user.name "${GITHUB_USER:-$(git config user.name)}"
else
  echo "  ⚠️  GITHUB_NOREPLY no está definido: el commit va con el correo de la máquina"
fi
git -C "$TARGET" add -A
if git -C "$TARGET" diff --cached --quiet; then
  echo "  (sin cambios respecto del commit anterior)"
else
  git -C "$TARGET" commit -q -m "P4W $VERSION

Native macOS GUI for Pi: spaces and tabs, full-text search over every session, an agent panel
that never reaps a busy instance, topic clustering without a model, and a white cat that tells
you what Pi is doing.

GPL-3.0. Universal binary (arm64 + x86_64), macOS 15+."
  echo "  ✓ commit hecho"
fi

if [[ "$PUSH" -eq 1 ]]; then
  echo "→ publicando en github.com/$REPO (PÚBLICO)"
  if ! git -C "$TARGET" remote get-url origin >/dev/null 2>&1; then
    gh repo create "$REPO" --public --source "$TARGET" --remote origin \
      --description "Native macOS GUI for Pi — spaces, search, agent panel, and a cat that says what Pi is doing" >/dev/null
    echo "  ✓ repo creado"
  fi
  git -C "$TARGET" push -q -u origin main
  echo "  ✓ main empujado"
fi

if [[ "$RELEASE" -eq 1 ]]; then
  echo "→ armando el release v$VERSION"
  scripts/build-dmg.sh >/dev/null
  DMG="dist/P4W-$VERSION.dmg"
  [[ -f "$DMG" ]] || { echo "✗ no se armó el .dmg"; exit 1; }
  git -C "$TARGET" tag -f "v$VERSION" >/dev/null
  git -C "$TARGET" push -q -f origin "v$VERSION"
  # The release notes come from the CHANGELOG section for this version: one place to write them.
  NOTES="$(awk "/^## \[$VERSION\]/{flag=1; next} /^## \[/{flag=0} flag" "$TARGET/CHANGELOG.md")"
  gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "P4W $VERSION" \
    --notes "${NOTES:-Release $VERSION}" >/dev/null
  echo "  ✓ release creado con $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"
fi

echo
echo "✓ árbol público listo en $TARGET"
if [[ "$PUSH" -eq 0 ]]; then
  echo "  para publicar:  scripts/publish.sh --push"
  echo "  con release:    scripts/publish.sh --release"
fi
