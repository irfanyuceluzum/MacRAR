#!/bin/zsh
# Downloads the 7-Zip command-line engine (7zz, universal) from 7-zip.org into tools/.
# RARLAB's rar/unrar are not bundled any more (rar may not be redistributed); RAR archives are read by 7-Zip.
# The download is checked against a pinned SHA-256 so a tampered or swapped file never ends up in a release.
# Another version: SEVENZIP_VERSION=2605 SEVENZIP_SHA256=<sha256 of 7z2605-mac.tar.xz> ./fetch-tools.sh
set -e
cd "$(dirname "$0")"
SEVENZIP_VERSION="${SEVENZIP_VERSION:-2604}"   # 7-Zip 26.04
# SHA-256 of 7z2604-mac.tar.xz (same file on github.com/ip7z/7zip and 7-zip.org)
PINNED_2604="bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578"
if [[ -z "$SEVENZIP_SHA256" ]]; then
  if [[ "$SEVENZIP_VERSION" == "2604" ]]; then
    SEVENZIP_SHA256="$PINNED_2604"
  else
    echo "✘ No pinned SHA-256 for 7-Zip $SEVENZIP_VERSION. Set SEVENZIP_SHA256 (shasum -a 256 7z${SEVENZIP_VERSION}-mac.tar.xz)."
    exit 1
  fi
fi
mkdir -p tools && cd tools
echo "▸ Downloading 7-Zip ${SEVENZIP_VERSION} for macOS"
curl -fL -o 7z.tar.xz "https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VERSION:0:2}.${SEVENZIP_VERSION:2:2}/7z${SEVENZIP_VERSION}-mac.tar.xz"
ACTUAL=$(shasum -a 256 7z.tar.xz | cut -d' ' -f1)
if [[ "$ACTUAL" != "$SEVENZIP_SHA256" ]]; then
  rm -f 7z.tar.xz
  echo "✘ SHA-256 mismatch for 7z${SEVENZIP_VERSION}-mac.tar.xz"
  echo "  expected $SEVENZIP_SHA256"
  echo "  got      $ACTUAL"
  exit 1
fi
echo "✔ SHA-256 verified"
rm -rf _7z && mkdir -p _7z
tar -xJf 7z.tar.xz -C _7z
cp _7z/7zz .
cp _7z/License.txt 7zip-license.txt
rm -rf _7z 7z.tar.xz
chmod +x 7zz
xattr -c 7zz 2>/dev/null || true
echo "✔ Tools ready in $(pwd):"; ls -1
