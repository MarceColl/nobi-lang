#!/bin/sh
# Kinoko installer: downloads the kinoko binary for this machine, verifies its
# sha256 and installs it. Never uses sudo, never edits shell rc files.
#
#   KINOKO_VERSION      release tag to install (default: latest)
#   KINOKO_BIN_DIR      where to put `kinoko` (default: $HOME/.local/bin)
#   KINOKO_BASE_URL     overrides the whole download base URL
#   KINOKO_REPO         GitHub owner/repo the releases live in
#
# Everything runs inside main(), called on the last line: a download cut short
# defines functions and runs nothing.
set -eu

KINOKO_REPO="${KINOKO_REPO:-OWNER/kinoko}"
KINOKO_VERSION="${KINOKO_VERSION:-latest}"

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# Set once the matching resource exists; the EXIT trap removes them.
tmp=""
staged=""
cleanup() {
  [ -z "$tmp" ] || rm -rf "$tmp"
  [ -z "$staged" ] || rm -f "$staged"
}

main() {
  # --- install dir ------------------------------------------------------------
  install_dir="${KINOKO_BIN_DIR:-}"
  if [ -z "$install_dir" ]; then
    [ -n "${HOME:-}" ] || die "neither KINOKO_BIN_DIR nor HOME is set; set KINOKO_BIN_DIR"
    install_dir="$HOME/.local/bin"
  fi
  while [ "${#install_dir}" -gt 1 ]; do
    case "$install_dir" in
      */) install_dir="${install_dir%/}" ;;
      *) break ;;
    esac
  done

  # --- download base ----------------------------------------------------------
  if [ -n "${KINOKO_BASE_URL:-}" ]; then
    base="${KINOKO_BASE_URL%/}"
  else
    case "$KINOKO_REPO" in
      *OWNER*) die "this installer has no release repository configured yet (KINOKO_REPO=$KINOKO_REPO). Set KINOKO_REPO=owner/kinoko or KINOKO_BASE_URL." ;;
    esac
    if [ "$KINOKO_VERSION" = "latest" ]; then
      base="https://github.com/$KINOKO_REPO/releases/latest/download"
    else
      base="https://github.com/$KINOKO_REPO/releases/download/$KINOKO_VERSION"
    fi
  fi

  # --- platform ---------------------------------------------------------------
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) die "unsupported OS: $os (supported: macOS, Linux)" ;;
  esac
  case "$arch" in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=x86_64 ;;
    *) die "unsupported architecture: $arch (supported: arm64, x86_64)" ;;
  esac
  # A shell running under Rosetta reports x86_64 on an arm64 Mac.
  if [ "$os" = macos ] && [ "$arch" = x86_64 ] &&
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
    arch=arm64
  fi
  name="kinoko-$os-$arch"

  # --- tools ------------------------------------------------------------------
  https_only=""
  case "$base" in https://*) https_only=1 ;; esac
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$https_only" ]; then
      fetch() { curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"; }
    else
      fetch() { curl -fsSL -o "$2" "$1"; }
    fi
  elif command -v wget >/dev/null 2>&1; then
    # Busybox wget (stock Alpine) has no --https-only and rejects it; the
    # checksum check below still applies either way.
    if [ -n "$https_only" ] && wget --help 2>&1 | grep -q -- --https-only; then
      fetch() { wget -q --https-only -O "$2" "$1"; }
    else
      fetch() { wget -q -O "$2" "$1"; }
    fi
  else
    die "need curl or wget"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
  elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
  else
    die "need sha256sum or shasum"
  fi

  # --- download and verify ----------------------------------------------------
  trap cleanup EXIT
  trap 'exit 130' INT TERM HUP
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/kinoko-install.XXXXXX")"

  say "Downloading $name ($KINOKO_VERSION)"
  fetch "$base/$name" "$tmp/$name" || die "could not download $base/$name"
  fetch "$base/$name.sha256" "$tmp/$name.sha256" || die "could not download $base/$name.sha256"

  expected="$(cut -d ' ' -f 1 "$tmp/$name.sha256" | head -n 1)"
  actual="$(sha256 "$tmp/$name")"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    die "checksum mismatch for $name (expected ${expected:-none}, got $actual); nothing installed"
  fi

  # --- install ----------------------------------------------------------------
  mkdir -p "$install_dir" || die "cannot create $install_dir"
  # Staged next to the target so the final mv is an atomic rename.
  staged="$install_dir/.kinoko.$$"
  cp "$tmp/$name" "$staged" || die "cannot write to $install_dir"
  chmod 0755 "$staged"
  mv -f "$staged" "$install_dir/kinoko" || die "cannot install to $install_dir/kinoko"
  staged=""

  say "Installed kinoko to $install_dir/kinoko"

  case ":${PATH:-}:" in
    *":$install_dir:"*) ;;
    *)
      say ""
      say "$install_dir is not on your PATH. Add it with:"
      case "${SHELL:-}" in
        */fish) say "  fish_add_path $install_dir" ;;
        *) say "  export PATH=\"$install_dir:\$PATH\"" ;;
      esac
      ;;
  esac

  say ""
  say "Next: run  kinoko"
}

main "$@"
