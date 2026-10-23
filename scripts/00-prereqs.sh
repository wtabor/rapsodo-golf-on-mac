#!/usr/bin/env bash
# Install whatever is missing: Rosetta 2 (Wine is an Intel build), Homebrew (it
# also brings Apple's command-line tools: clang, swift, git, python3), the build
# tools, and iTerm (the app inherits its Local Network permission). Anything
# already installed is skipped.
set -euo pipefail

if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "Installing Rosetta 2..."
  sudo softwareupdate --install-rosetta --agree-to-license
fi

if ! command -v brew >/dev/null; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
fi
if ! command -v brew >/dev/null; then
  echo "Installing Homebrew (it asks for your Mac password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

missing=()
for f in mingw-w64 cmake libusb; do
  brew list --formula "$f" >/dev/null 2>&1 || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "Installing ${missing[*]}..."
  brew install "${missing[@]}"
fi

if [ ! -d /Applications/iTerm.app ]; then
  echo "Installing iTerm..."
  brew install --cask iterm2
fi
