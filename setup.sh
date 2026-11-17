#!/bin/sh
# Installs csshm into /usr/local/bin.
#
#   curl -s https://raw.githubusercontent.com/anarchy89/csshm/main/setup.sh | sh
#
# It downloads the latest released binary, checks that it runs and copies it
# into place. Run it again at any time to reinstall.
set -e

url="https://github.com/anarchy89/csshm/releases/latest/download/csshm"
folder="/usr/local/bin"
download=$(mktemp -t csshm)
trap 'rm -f "$download"' EXIT

echo "Downloading csshm..."
if ! curl -fsSL -o "$download" "$url"; then
    echo "Could not download $url" >&2
    exit 1
fi
chmod 755 "$download"
if ! "$download" --version > /dev/null 2>&1; then
    echo "The downloaded file does not run on this Mac. csshm needs macOS 13 or later." >&2
    exit 1
fi

if [ -d "$folder" ] && [ -w "$folder" ]; then
    install -m 755 "$download" "$folder/csshm"
else
    echo "Installing into $folder needs your password."
    sudo mkdir -p "$folder"
    sudo install -m 755 "$download" "$folder/csshm"
fi

echo "Installed $("$folder/csshm" --version) in $folder."
echo "Run: csshm --help"
