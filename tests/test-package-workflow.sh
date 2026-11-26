#!/usr/bin/env bash
# shellcheck disable=SC2016

# Contrato offline del pipeline de empaquetado y publicación del .pkg
# (package.yml, issue #9): estructura del workflow, consistencia
# PKGBUILD/.SRCINFO/tarball vendoreado contra el sha real medido del
# archive del tag, el package() real del PKGBUILD contra el tarball
# commiteado, y el contrato de publicación en stable/x86_64 de
# omarchy-personal-repo. Cada aserción dura lleva su caso por mutación.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly PACKAGE_DIR
readonly WORKFLOW="$PACKAGE_DIR/.github/workflows/package.yml"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/package-workflow-test.XXXXXX")"
readonly TEST_ROOT

trap 'rm -rf "$TEST_ROOT"' EXIT

die() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

have() {
  grep -qF -- "$1" "$WORKFLOW" || die "package.yml no tiene: $1"
}

miss() {
  ! grep -qF -- "$1" "$2" || die "$3"
}

expect_fail() { # expect_fail <por qué debe fallar> <cmd...>
  local why="$1"; shift
  # En subshell: die del check hace exit y no debe matar el test entero.
  if ( "$@" ) > /dev/null 2>&1; then
    die "la mutación no fue detectada: $why"
  fi
}

# El run body de un paso nombrado, extraído del YAML y sin sangría: es la
# lógica que el workflow va a correr, probada en vez de confiada.
extract_run() {
  awk -v step="$1" '
    $0 == "      - name: " step { found_step = 1; next }
    found_step && /^        run: \|/ { in_run = 1; next }
    in_run {
      if ($0 ~ /^ {10}/) { sub(/^ {10}/, ""); print; next }
      if ($0 ~ /^[[:space:]]*$/) { next }
      exit
    }
  ' "${2:-$WORKFLOW}"
}

# Estructura de package.yml: triggers sin push, contenedor Arch, build desde
# el tarball vendoreado, install-test del .pkg, artifact y publicación.
have 'repository_dispatch:'
have 'source-updated'
have 'workflow_dispatch:'
have 'image: archlinux:base'
have 'Checkout this package repository'
have 'no quedó exactamente un tarball vendoreado'
have 'no coincide con pkgver del PKGBUILD'
have 'makepkg'
have 'pacman -U --noconfirm'
have '/usr/share/ravn/common'
have 'bin/ravn-home-sync'
have 'pacman -Qkk ravn-home-common'
have 'actions/upload-artifact@v4'
have 'path: build/*.pkg.tar.zst'
have 'if-no-files-found: error'
# Este repo no despacha una fuente: el tarball vendoreado ES la fuente.
miss 'Checkout the source at the dispatched commit' "$WORKFLOW" \
  'package.yml despacha una fuente externa que este repo no tiene'

# El orden importa: archlinux:base no trae git, así que las dependencias se
# instalan antes del primer checkout (el fallback REST deja un árbol sin .git;
# lección del run real del repo del patrón, y el mismo orden del CI).
deps_line="$(grep -n '      - name: Install build and runtime dependencies' "$WORKFLOW" | cut -d: -f1)"
checkout_line="$(grep -n '      - name: Checkout this package repository' "$WORKFLOW" | cut -d: -f1)"
[[ -n "$deps_line" && -n "$checkout_line" && "$deps_line" -lt "$checkout_line" ]] || \
  die 'las dependencias van antes del checkout (la imagen base no trae git)'

# ----------------------------------------------------------------------
# Contrato del paquete: exactamente un tarball vendoreado, y la versión,
# el nombre de source y el sha256 coinciden entre el archivo real, el
# PKGBUILD y el .SRCINFO. El sha real se midió descargando la URL del
# archive del tag (la que el PKGBUILD viejo fetchaba) con credenciales:
# 3cff83fc... es lo que GitHub sirve para refs/tags/v0.1.1, y la
# regeneración local `git archive --prefix=ravn-home-common-0.1.1/ v0.1.1
# | gzip -n` es byte-igual. El sha viejo (113721b5...) no coincide con
# ningún archive medible: ni con el del tag ni con el de main
# (89264e42...), que además es DIFERENTE al del tag, así que "main da el
# mismo sha" no se cumple. Hallazgo de un run real, fijado como aserción.
# ----------------------------------------------------------------------
readonly TAG_ARCHIVE_SHA='3cff83fc9041d08eef4be03f0f531ec7db8f334db9f0553ae288f2cae19f4261'

tarballs=("$PACKAGE_DIR"/ravn-home-common-*.tar.gz)
if (( ${#tarballs[@]} != 1 )) || [[ ! -e "${tarballs[0]}" ]]; then
  die 'no hay exactamente un tarball vendoreado en la raíz del repo'
fi
tarball="$(basename "${tarballs[0]}")"
pkgver="$(awk -F= '/^pkgver=/{print $2; exit}' "$PACKAGE_DIR/PKGBUILD")"
pkgrel="$(awk -F= '/^pkgrel=/{print $2; exit}' "$PACKAGE_DIR/PKGBUILD")"
[[ "$tarball" == "ravn-home-common-${pkgver}.tar.gz" ]] || \
  die "el tarball vendoreado ($tarball) no coincide con pkgver del PKGBUILD ($pkgver)"
[[ "$pkgver" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "pkgver inválido: $pkgver"
[[ "$pkgrel" =~ ^[0-9]+$ ]] || die "pkgrel inválido: $pkgrel"
grep -qF 'source=("${pkgname}-${pkgver}.tar.gz")' "$PACKAGE_DIR/PKGBUILD" || \
  die 'el PKGBUILD no declara el tarball vendoreado parametrizado en source'
# La URL del archive era la fuente y quedó fuera: ravn-home-common es un
# repo privado y la URL da 404 sin credenciales, y el sha que declaraba
# salió de otra fuente (ningún archive medible lo produce).
miss 'archive/refs/tags' "$PACKAGE_DIR/PKGBUILD" 'PKGBUILD todavía fetcha el archive del tag'
miss 'archive/refs/tags' "$PACKAGE_DIR/.SRCINFO" '.SRCINFO todavía fetcha el archive del tag'
real_sha="$(sha256sum "${tarballs[0]}" | awk '{print $1}')"
[[ "$real_sha" == "$TAG_ARCHIVE_SHA" ]] || \
  die "el tarball commiteado no es el archive real del tag: $real_sha != $TAG_ARCHIVE_SHA"
pkgb_sha="$(grep -oE '[0-9a-f]{64}' "$PACKAGE_DIR/PKGBUILD" | head -1)"
srcinfo_sha="$(awk '/^\tsha256sums = /{print $3; exit}' "$PACKAGE_DIR/.SRCINFO")"
[[ "$pkgb_sha" == "$real_sha" ]] || \
  die "el sha256 del PKGBUILD no es el del tarball commiteado: $pkgb_sha != $real_sha"
[[ "$srcinfo_sha" == "$real_sha" ]] || \
  die "el sha256 del .SRCINFO no es el del tarball commiteado: $srcinfo_sha != $real_sha"
grep -qE "^$(printf '\t')pkgver = ${pkgver}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO pkgver no coincide con el PKGBUILD'
grep -qE "^$(printf '\t')pkgrel = ${pkgrel}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO pkgrel no coincide con el PKGBUILD'
grep -qE "^$(printf '\t')source = ${tarball}$" "$PACKAGE_DIR/.SRCINFO" || \
  die '.SRCINFO source no declara el tarball vendoreado'

# El paso de staging es bash válido y corre de verdad: deja PKGBUILD y el
# tarball en el build dir, con su guardia de tarball único.
stage_script="$TEST_ROOT/stage.sh"
extract_run 'Stage the build directory' > "$stage_script"
[[ -s "$stage_script" ]] || die 'no se pudo extraer el paso de staging de package.yml'
bash -n "$stage_script" || die 'el paso de staging no es bash válido'
run_stage() { # run_stage <repo_dir> <build_dir>
  (
    set -Eeuo pipefail
    cd "$1"
    PKG_BUILD="$2" GITHUB_OUTPUT="$TEST_ROOT/stage-output" bash "$stage_script"
  )
}
stage_repo="$TEST_ROOT/stage-repo"
mkdir -p "$stage_repo"
cp "$PACKAGE_DIR/PKGBUILD" "$PACKAGE_DIR/$tarball" "$stage_repo/"
run_stage "$stage_repo" "$TEST_ROOT/build-stage"
[[ -f "$TEST_ROOT/build-stage/PKGBUILD" && -f "$TEST_ROOT/build-stage/$tarball" ]] || \
  die 'el staging no dejó PKGBUILD y tarball en el build dir'
# Mutación: un tarball viejo olvidado en la raíz debe morir en la guardia.
cp -r "$stage_repo" "$TEST_ROOT/stage-repo-doble"
: > "$TEST_ROOT/stage-repo-doble/ravn-home-common-9.9.9.tar.gz"
expect_fail 'dos tarballs vendoreados en la raíz' \
  run_stage "$TEST_ROOT/stage-repo-doble" "$TEST_ROOT/build-stage-doble"

# El paso de build/install es bash válido (el resto corre en el contenedor
# real del primer dispatch: pacman y makepkg no existen acá).
build_script="$TEST_ROOT/build.sh"
extract_run 'Build the package and install-test it' > "$build_script"
[[ -s "$build_script" ]] || die 'no se pudo extraer el paso de build de package.yml'
bash -n "$build_script" || die 'el paso de build no es bash válido'

# ----------------------------------------------------------------------
# package() funciona: contra el tarball vendoreado commiteado se corre el
# package() real del PKGBUILD con DESTDIR temporal (el WK nunca instala
# en el sistema) y se fuma el payload staged con el mismo contrato que
# verifica el paso de install-test del workflow.
# ----------------------------------------------------------------------
srcroot="$TEST_ROOT/pkg-src"
rm -rf "$srcroot"
mkdir -p "$srcroot"
tar -xzf "$PACKAGE_DIR/$tarball" -C "$srcroot"
[[ -d "$srcroot/ravn-home-common-${pkgver}" ]] || \
  die "el tarball no descomprime con la raíz que el package() espera: ravn-home-common-${pkgver}/"

run_package() { # run_package <pkgdir> <pkgbuild>
  (
    set -Eeuo pipefail
    # srcdir y pkgdir los consume package() del PKGBUILD al invocarse;
    # el disable marca que el uso es dinámico.
    # shellcheck disable=SC2034
    srcdir="$srcroot" pkgdir="$1"
    rm -rf "$1"
    # shellcheck disable=SC1090
    source "$2"
    package
  )
}

check_installed() { # check_installed <pkgdir>
  local payload="$1/usr/share/ravn/common"
  [[ -f "$payload/bash/rc" ]] || return 1
  [[ -f "$payload/fish/config.fish" ]] || return 1
  [[ -f "$payload/alacritty/alacritty.toml" ]] || return 1
  [[ -f "$payload/fcitx5/conf/classicui.conf" ]] || return 1
  [[ -f "$payload/gtk-3.0/settings.ini" ]] || return 1
  [[ -f "$payload/gtk-4.0/settings.ini" && -f "$payload/gtk-4.0/gtk.css" ]] || return 1
  [[ -d "$payload/gtk-4.0/assets" && -n "$(ls -A "$payload/gtk-4.0/assets")" ]] || return 1
  [[ -f "$payload/mpv/mpv.conf" && -f "$payload/mpv/scripts/uosc/main.lua" ]] || return 1
  [[ -x "$payload/bin/ravn-home-sync" ]] || return 1
  # El script instalado corre: usage y un dry-run completo sin estado
  # (el mismo smoke del paso de install-test del workflow).
  "$payload/bin/ravn-home-sync" --help 2>&1 | grep -qF 'Uso' || return 1
  local out
  out="$("$payload/bin/ravn-home-sync" -n -t "$1/test-home" -s "$payload" 2>&1)" || return 1
  grep -qF 'DRY-RUN' <<<"$out" || return 1
  grep -qF 'completado' <<<"$out" || return 1
  return 0
}

good_pkgbuild="$TEST_ROOT/PKGBUILD.good"
cp "$PACKAGE_DIR/PKGBUILD" "$good_pkgbuild"
run_package "$TEST_ROOT/pkg-good" "$good_pkgbuild"
check_installed "$TEST_ROOT/pkg-good" || die 'el payload staged no cumple el contrato de instalación (caso bueno)'

# Mutación: sin bash/rc no hay capa bash y el check lo detecta.
sed '/install -m644 "${src}\/bash\/rc"/d' "$good_pkgbuild" \
  > "$TEST_ROOT/PKGBUILD.sin-bash"
run_package "$TEST_ROOT/pkg-sin-bash" "$TEST_ROOT/PKGBUILD.sin-bash"
expect_fail 'payload sin bash/rc' check_installed "$TEST_ROOT/pkg-sin-bash"

# Mutación: sin el bin/ravn-home-sync el smoke del script se cae y el check lo detecta.
sed '/install -m755 "${src}\/bin\/ravn-home-sync"/d' "$good_pkgbuild" \
  > "$TEST_ROOT/PKGBUILD.sin-bin"
run_package "$TEST_ROOT/pkg-sin-bin" "$TEST_ROOT/PKGBUILD.sin-bin"
expect_fail 'payload sin bin/ravn-home-sync' check_installed "$TEST_ROOT/pkg-sin-bin"

# ----------------------------------------------------------------------
# Los defaults del workflow_dispatch no admiten expresiones ${{ }}:
# GitHub Actions las rechaza en los defaults de inputs (hallazgo del run
# real del repo del patrón). Este repo no usa inputs, así que la
# aserción vigila el bloque entero y la mutación le inyecta uno con
# expresión.
# ----------------------------------------------------------------------
check_dispatch_inputs_literal() { # check_dispatch_inputs_literal <workflow_file>
  local workflow="$1" block
  block="$(awk '
    /^  workflow_dispatch:/ { in_wd = 1; next }
    in_wd {
      if (/^ {4}/) { print; next }
      if (/^[[:space:]]*$/) { next }
      exit
    }
  ' "$workflow")"
  if grep -qF '${{' <<<"$block"; then
    die "on.workflow_dispatch contiene una expresión \${{ }}: GitHub Actions no admite expresiones en el bloque"
  fi
}
have 'workflow_dispatch:'
check_dispatch_inputs_literal "$WORKFLOW"

mutated_workflow="$TEST_ROOT/package-with-expression.yml"
sed 's|^  workflow_dispatch:$|  workflow_dispatch:\n    inputs:\n      repo:\n        default: ${{ github.repository }}|' \
  "$WORKFLOW" > "$mutated_workflow"
grep -qF '${{ github.repository }}' "$mutated_workflow" || die 'la mutación del bloque workflow_dispatch no se aplicó'
expect_fail 'default con expresión ${{ }}' check_dispatch_inputs_literal "$mutated_workflow"

# Opción A: package.yml NO debe publicar directo a gh-pages ni usar omarchy-pkgs.
miss 'bash omarchy-pkgs/bin/publish-artifact' "$WORKFLOW" 'package.yml no debe publicar directo a gh-pages (opción A)'
miss 'ref: gh-pages' "$WORKFLOW" 'package.yml no debe tocar gh-pages (opción A)'
printf 'PASS: %s (opción A)\n' "$WORKFLOW"
