#!/bin/zsh
# Birim testleri: Xcode projesi, XCTest ve üçüncü parti bağımlılık olmadan çalışır.
#   ./test.sh
# Sources/*.swift (main.swift hariç) + Tests/*.swift tek bir test ikilisine derlenir ve çalıştırılır.
# Çeviri denetimi de testlerin içindedir (L("…") / LF("… anahtarları L10n.en tablosunda var mı).
# Çıktı: build/tests/. Herhangi bir test kalırsa çıkış kodu ≠ 0.
set -e
cd "$(dirname "$0")"
PROJ="$PWD"
OUT="$PROJ/build/tests"
rm -rf "$OUT"
mkdir -p "$OUT"

SRC=()
for f in Sources/*.swift; do
  [[ "${f:t}" == main.swift ]] && continue
  SRC+=("$f")
done

echo "▸ Testler derleniyor"
# Test kancaları (-D MACRAR_DEBUG_HOOKS) kasıtlı olarak yok: testler yayın davranışını sınar
swiftc -swift-version 5 \
  -framework AppKit -framework UniformTypeIdentifiers -framework Quartz \
  -module-name MacRARTests "${SRC[@]}" Tests/*.swift -o "$OUT/macrar-tests"

# Her iki dilde de çalıştır: testler dile bağlı beklentileri L(...) ile hesaplar
rc=0
for lang in tr en; do
  echo "▸ Testler çalışıyor (MACRAR_LANG=$lang)"
  MACRAR_LANG=$lang MACRAR_SOURCES_DIR="$PROJ/Sources" MACRAR_NO_UPDATE_CHECK=1 "$OUT/macrar-tests" || rc=1
done

if [[ $rc -eq 0 ]]; then echo "✔ Tüm testler geçti"; else echo "✘ Testler başarısız"; fi
exit $rc
