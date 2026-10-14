#!/bin/zsh
# Yayın paketi: imzalama (+ Apple notarize), ZIP ve DMG, isteğe bağlı GitHub Releases yüklemesi
#
# Ön koşullar (Apple onaylı yayın için, bir kez):
#   1) Xcode → Settings → Accounts → hesabınız → Manage Certificates… → + → "Developer ID Application"
#   2) App Store Connect'te uygulamaya özel parola oluşturup notarytool profiline kaydedin:
#        xcrun notarytool store-credentials MacRAR --apple-id APPLE_ID --team-id TEAMID
#      (parolayı komut kendisi sorar; betiğe yazılmaz)
#
# Kullanım:  ./release.sh                      → sertifikayı otomatik bulur, profil adı "MacRAR"
#            ./release.sh publish              → ek olarak DMG ve ZIP'i GitHub Releases'a yükler (gh gerekir)
#            IDENTITY="Developer ID Application: Ad (TEAMID)" PROFILE=MacRAR ./release.sh
#
# Fork'tan yayın:
#            RELEASE_REPO=sahip/ad ./release.sh publish
#              → sürüm o depoya yüklenir; uygulama güncellemeleri de o depodan denetler (MACRAR_UPDATE_REPO).
#                Etiket, o depoda zaten bulunan geçerli dala (RELEASE_TARGET, varsayılan: geçerli dal) bağlanır.
#            ADHOC=1 ./release.sh …
#              → Developer ID sertifikası yoksa: yalnız bu Mac'e özgü (ad-hoc) imza, notarize YOK.
#                İndiren kişi ilk açılışta macOS uyarısı görür (sağ tık → Aç ya da Sistem Ayarları → Gizlilik ve Güvenlik).
#            NOTES_FILE=dosya.md               → sürüm notları (varsayılan RELEASE_NOTES.md)
set -e
cd "$(dirname "$0")"
APP="build/MacRAR.app"
DEFAULT_REPO="mstcvk/MacRAR"
RELEASE_REPO="${RELEASE_REPO:-${MACRAR_UPDATE_REPO:-$DEFAULT_REPO}}"
[[ "$RELEASE_REPO" =~ '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' ]] || { echo "✘ RELEASE_REPO 'sahip/ad' biçiminde olmalı"; exit 1; }
NOTES="${NOTES_FILE:-RELEASE_NOTES.md}"
[[ -f "$NOTES" ]] || { echo "✘ Sürüm notları bulunamadı: $NOTES"; exit 1; }

# Sertifika: önce bulunur, imza kipi derlemeden önce kesinleşsin
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
fi
if [[ -n "$IDENTITY" ]]; then
  SIGNING=notarized
elif [[ "$ADHOC" == 1 ]]; then
  SIGNING=adhoc
else
  echo "Developer ID Application sertifikası bulunamadı. Xcode → Settings → Accounts → Manage Certificates… ile oluşturun"
  echo "ya da Apple onayı olmadan yayımlamak için ADHOC=1 ile çalıştırın."
  exit 1
fi

# Her zaman yeniden derle: eski bir build/ kopyası Info.plist'teki sürümden geride kalabilir (1.4.3'te yaşandı)
# Yayın sürümüne test kancaları girmesin; uygulama güncellemeleri yayımlandığı depodan denetlesin
unset MACRAR_DEBUG_HOOKS
if [[ "$RELEASE_REPO" != "$DEFAULT_REPO" ]]; then export MACRAR_UPDATE_REPO="$RELEASE_REPO"; else unset MACRAR_UPDATE_REPO; fi
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "▸ Sürüm $VERSION → $RELEASE_REPO ($SIGNING)"
PROFILE="${PROFILE:-MacRAR}"
mkdir -p dist
ZIP="dist/MacRAR-$VERSION.zip"
DMG="dist/MacRAR-$VERSION.dmg"

make_dmg() {
  local stage
  stage=$(mktemp -d)
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  rm -f "$DMG"
  hdiutil create -volname "MacRAR" -srcfolder "$stage" -ov -format UDZO -quiet "$DMG"
  rm -rf "$stage"
}

if [[ $SIGNING == notarized ]]; then
  echo "▸ İmzalanıyor: $IDENTITY"
  for bin in 7zz; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/$bin"
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "▸ Notarize için paketleniyor"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "▸ Apple'a gönderiliyor (notarytool profili: $PROFILE)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  echo "▸ Onay damgası (staple) ekleniyor"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP" && echo "✔ Gatekeeper onaylı: $ZIP"

  echo "▸ DMG oluşturuluyor"
  make_dmg
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "▸ DMG notarize ediliyor"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" && echo "✔ Gatekeeper onaylı: $DMG"
else
  # build.sh sertifika yokken ad-hoc imzalar
  codesign --verify --deep --strict "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "▸ DMG oluşturuluyor"
  make_dmg
  echo "⚠ Ad-hoc imzalı, Apple onaysız paket: indiren kişi ilk açılışta macOS uyarısı görür"
  echo "✔ Hazır: $ZIP, $DMG"
fi

if [[ "$1" == "publish" ]]; then
  export PATH="$HOME/.local/bin:$PATH"
  TARGET="${RELEASE_TARGET:-$(git rev-parse --abbrev-ref HEAD)}"
  # Etiket yayın deposundaki bu dala bağlanır: dal oraya gönderilmiş ve yerel kopyayla aynı olmalı
  REMOTE_SHA=$(git ls-remote "https://github.com/$RELEASE_REPO.git" "refs/heads/$TARGET" | cut -f1)
  if [[ "$REMOTE_SHA" != "$(git rev-parse HEAD)" ]]; then
    echo "✘ '$TARGET' dalı $RELEASE_REPO deposunda yok ya da yerel kopyadan farklı. Önce gönderin: git push <uzak> $TARGET"
    exit 1
  fi
  echo "▸ GitHub Releases'a yükleniyor ($RELEASE_REPO, v$VERSION, dal: $TARGET)"
  if gh release view "v$VERSION" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" "$ZIP" --repo "$RELEASE_REPO" --clobber
  else
    gh release create "v$VERSION" "$DMG" "$ZIP" --repo "$RELEASE_REPO" --target "$TARGET" \
      --title "MacRAR $VERSION" --notes-file "$NOTES"
  fi
  echo "✔ Yayınlandı: $(gh release view "v$VERSION" --repo "$RELEASE_REPO" --json url -q .url)"
  # Homebrew tap (github.com/mstcvk/homebrew-tap): yalnız ana depodan yayında ya da TAP_DIR açıkça verildiyse
  if [[ "$RELEASE_REPO" == "$DEFAULT_REPO" || -n "$TAP_DIR" ]]; then
    TAP_DIR="${TAP_DIR:-$(dirname "$PWD")/homebrew-tap}"
    if [[ -f "$TAP_DIR/Casks/macrar.rb" ]]; then
      echo "▸ Homebrew cask güncelleniyor ($TAP_DIR)"
      SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
      sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP_DIR/Casks/macrar.rb"
      if git -C "$TAP_DIR" diff --quiet; then
        echo "  cask zaten güncel"
      else
        git -C "$TAP_DIR" commit -qam "macrar $VERSION" && git -C "$TAP_DIR" push -q
        echo "✔ Homebrew cask → $VERSION"
      fi
    else
      echo "  Homebrew tap bulunamadı ($TAP_DIR); cask elle güncellenmeli"
    fi
  fi
fi
