## MacRAR 1.5.0 (irfanyuceluzum fork)

Bu sürüm Apple onaylı değildir: ilk açılışta macOS uyarı verirse uygulamaya sağ tıklayıp **Aç**'ı seçin (ya da Sistem Ayarları → Gizlilik ve Güvenlik → **Yine de Aç**). Güncellemeler bu fork'tan denetlenir.

**Veri güvenliği**
- tar.gz/xz/bz2 + "kaynak dosyaları sil": iptal ya da hata durumunda kaynaklar artık kaybolmuyor; yalnız tüm adımlar başarılıysa çöpe taşınıyor.
- Finder'a sürüklemede aynı adlı öğe sorulmadan silinmiyor (üzerine yaz / yeniden adlandır / atla; eskisi çöpe).
- Dosya adlarındaki `*` ve `?` artık joker sayılmıyor ("st*r.txt" silinirken "stXr.txt" silinmiyor).
- ZIP'te yanlış şifre artık hedefte boş dosyalar bırakmıyor.

**Doğruluk ve güvenlik**
- Bozuk tar.gz arşivleri artık "Test başarılı" görünmüyor.
- `../` içeren arşivler hedef klasörün dışına dokunmuyor; geçici (şifresi çözülmüş) dosyalar daha erken siliniyor.
- Süren bir işlem varken çıkınca uyarı geliyor; arkada 7zz süreci kalmıyor.

**Yenilikler**
- Büyük arşivler arka planda açılıyor ("Yükleniyor…" + İptal), arama yazarken takılmıyor.
- Ayarlar → Görünüm: Sistem / Açık / Koyu.
- `.DS_Store` ve `__MACOSX` arşive eklenmiyor (Ayarlar'dan kapatılabilir; RAR'da uygulanmaz).

---

**English:** Unofficial build from the irfanyuceluzum fork (not notarized: right-click → Open on first launch). Data-loss fixes for tar.gz with "delete source files" and drag-to-Finder, literal `*`/`?` in file names, no empty files after a wrong ZIP password, corrupt tar.gz no longer reported as OK, safer handling of `../` entries and temporary files, stop running jobs on quit, background loading, Appearance setting, and an option (on by default) to leave `.DS_Store` / `__MACOSX` out of new archives.

**Requirements:** macOS 13+ (Apple Silicon and Intel).
