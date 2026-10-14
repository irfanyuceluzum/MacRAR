import AppKit

/// Tüm arşiv işlemleri: hem pencereden hem de Finder hızlı eylemlerinden kullanılır.
enum Ops {

    // MARK: Ortak iş çalıştırıcı (ilerleme penceresiyle)

    static func runJob(title: String, stages: [Stage], cwd: String? = nil,
                       host: NSWindow?, totalFiles: Int?, stripPrefix: String? = nil,
                       completion: @escaping (RarResult) -> Void) {
        let panel = ProgressPanel(title: title)
        panel.stripPrefix = stripPrefix
        let job = RarJob()
        var sawPercent = false
        var fileIndex = 0
        var lastName = ""
        job.onEvent = { ev in
            switch ev {
            case .file(let name):
                panel.setFile(name)
                if name != lastName {
                    lastName = name
                    fileIndex += 1
                    // Yüzde bilgisi gelmeyen boru hattı işlemlerinde dosya sayısına göre ilerle
                    if !sawPercent, let total = totalFiles, total > 0 {
                        panel.setFraction(Double(min(fileIndex, total)) / Double(total))
                    }
                }
            case .progress(let pct):
                // rar/unrar/7zz yüzdesi arşivin toplam ilerlemesidir
                sawPercent = true
                panel.setFraction(Double(pct) / 100.0)
            }
        }
        // panel ↔ job iş sürerken birbirini canlı tutar; bitince döngü kırılır (yoksa ikisi de sızar)
        panel.onCancel = { job.cancel() }
        panel.show(on: host)
        job.start(stages: stages, cwd: cwd) { [weak job] result in
            job?.onEvent = nil
            panel.onCancel = nil
            panel.dismiss()
            completion(result)
        }
    }

    static func runJob(title: String, tool: RarTool, args: [String], cwd: String? = nil,
                       host: NSWindow?, totalFiles: Int?, stripPrefix: String? = nil,
                       completion: @escaping (RarResult) -> Void) {
        runJob(title: title, stages: [(tool, args)], cwd: cwd, host: host, totalFiles: totalFiles, stripPrefix: stripPrefix, completion: completion)
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: Listeleme (şifre döngüsüyle)

    /// Süren bir listeleme (şifre denemeleri boyunca aynı tutamaç); iptal edilebilir
    final class ListTask {
        fileprivate var job: ListJob?
        private(set) var cancelled = false
        func cancel() { cancelled = true; job?.cancel() }
    }

    /// Arşivi arka planda listeler; gerekirse şifre sorar (soru ana iş parçacığında).
    /// completion(info, kullanılan şifre) her zaman ana kuyrukta ve asenkron çağrılır; iptal / hatada info nil.
    /// showPanel: penceresi olmayan çağrılar (Finder komutları) için uzun süren listelemede iptal edilebilir ilerleme penceresi
    @discardableResult
    static func list(archive: String, password: String?, showPanel: Bool = false, host: NSWindow? = nil,
                     completion: @escaping (ArchiveInfo?, String?) -> Void) -> ListTask {
        let task = ListTask()
        let folder = (archive as NSString).deletingLastPathComponent
        if Formats.isMultiVolume(archive) || !FileManager.default.isReadableFile(atPath: archive) {
            guard FolderAccess.ensure(folder, write: false) else {
                DispatchQueue.main.async { completion(nil, password) }
                return task
            }
        }
        func attempt(_ pw: String?, wrong: Bool) {
            let job = ListJob()
            task.job = job
            let closePanel = showPanel ? delayedListPanel(archive, host: host, onCancel: { task.cancel() }) : {}
            job.start(archive, password: pw) { outcome in
                closePanel()
                guard let outcome, !task.cancelled else { completion(nil, pw); return }
                switch outcome {
                case .ok(var info):
                    if wrong { info.headersEncrypted = true }   // şifre olmadan listelenemedi
                    completion(info, pw)
                case .wrongPassword:
                    guard let p = Dialogs.askPassword(archiveName: name(archive), wrong: wrong) else { completion(nil, pw); return }
                    attempt(p, wrong: true)
                case .error(let r):
                    if r.notArchive {
                        Dialogs.error(L("Arşiv açılamadı"), LF("\"%@\" desteklenen bir arşiv değil.", name(archive)))
                    } else {
                        Dialogs.error(L("Arşiv açılamadı"), r.errorSummary, details: r.output)
                    }
                    completion(nil, pw)
                }
            }
        }
        attempt(password, wrong: false)
        return task
    }

    /// Listeleme 0,5 sn'yi aşarsa iptal edilebilir bir ilerleme penceresi açar (kısa listelemelerde pencere yanıp sönmesin).
    /// Dönen kapanış pencereyi kapatır.
    private static func delayedListPanel(_ archive: String, host: NSWindow?, onCancel: @escaping () -> Void) -> () -> Void {
        var panel: ProgressPanel?
        var done = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !done else { return }
            let p = ProgressPanel(title: LF("Okunuyor: %@", name(archive)))
            p.setActivity(L("Arşiv içeriği listeleniyor…"))
            p.onCancel = onCancel
            p.show(on: host)
            panel = p
        }
        return {
            done = true
            panel?.onCancel = nil
            panel?.dismiss()
            panel = nil
        }
    }

    // MARK: Çıkartma

    /// Çıkartılacak öğeler arasında şifreli olan var mı? (names nil → tüm arşiv)
    static func needsPassword(info: ArchiveInfo, names: [String]?) -> Bool {
        if info.headersEncrypted { return true }
        guard let names else { return info.hasEncryptedFiles }
        return info.entries.contains { e in
            e.encrypted && names.contains { n in e.name == n || e.name.hasPrefix(n + "/") }
        }
    }

    enum OverwriteArg { case overwrite, rename, skip }

    static func extractStages(info: ArchiveInfo, names: [String]?, dest: String, password: String?, mode: OverwriteArg) -> [Stage] {
        let ow = mode == .overwrite ? "-aoa" : (mode == .rename ? "-aou" : "-aos")
        if info.tarCompressed {
            var inner = ["x", "-si", "-ttar", "-y", "-bb1", ow, "-o" + dest]
            if let names { inner += ["--"] + names }
            return [(.sevenZip, ["x", "-so", RarRunner.passwordArg7z(password), "--", info.path]),
                    (.sevenZip, inner)]
        }
        var args = ["x", "-y", "-bsp1", "-bb1", ow, RarRunner.passwordArg7z(password), "-o" + dest, "--", info.path]
        if let names { args += names }
        return [(.sevenZip, args)]
    }

    /// names: nil ise tüm arşiv. completion(success, kullanılan şifre)
    static func extract(info: ArchiveInfo, names: [String]?, dest: String, password: String?,
                        host: NSWindow?, quiet: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        guard FolderAccess.ensure(FolderAccess.existingAncestor(of: dest), write: true) else { completion(false, password); return }
        var pw = password
        if needsPassword(info: info, names: names), pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        // Üzerine yazma kontrolü
        let tops = topLevelNames(info: info, names: names)
        let existing = tops.filter { FileManager.default.fileExists(atPath: (dest as NSString).appendingPathComponent($0)) }
        var mode: OverwriteArg = .overwrite
        if !existing.isEmpty {
            switch Dialogs.askOverwrite(existing: existing, dest: dest) {
            case .overwrite: mode = .overwrite
            case .rename: mode = .rename
            case .skip: mode = .skip
            case .cancel: completion(false, pw); return
            }
        }
        let count = names == nil ? info.entries.count : nil
        runExtract(info: info, names: names, dest: dest, password: pw, mode: mode, host: host, count: count, quiet: quiet, completion: completion)
    }

    private static func runExtract(info: ArchiveInfo, names: [String]?, dest: String, password: String?, mode: OverwriteArg,
                                   host: NSWindow?, count: Int?, quiet: Bool, completion: @escaping (Bool, String?) -> Void) {
        let stages = extractStages(info: info, names: names, dest: dest, password: password, mode: mode)
        let quarantine = Quarantine.value(of: info.path)
        let started = Date()
        func finish(_ r: RarResult) {
            if r.cancelled { completion(false, password); return }
            if r.wrongPassword {
                guard let pw = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, password); return }
                runExtract(info: info, names: names, dest: dest, password: pw, mode: mode, host: host, count: count, quiet: quiet, completion: completion)
                return
            }
            if !r.ok {
                Dialogs.error(L("Çıkartma başarısız"), r.errorSummary, details: r.output)
                completion(false, password)
                return
            }
            if r.code == 1, !quiet {
                Dialogs.info(L("Çıkartma uyarılarla tamamlandı"), r.errorSummary)
            }
            completion(true, password)
        }
        runJob(title: LF("Çıkartılıyor: %@", name(info.path)), stages: stages, host: host, totalFiles: count, stripPrefix: dest) { r in
            // Yarım kalan çıkartmalar dahil, yazılan her öğe arşivin karantinasını alır (sonuç işlenmeden, açılmadan önce)
            guard let quarantine else { finish(r); return }
            let tops = topLevelNames(info: info, names: names)
            DispatchQueue.global(qos: .userInitiated).async {
                Quarantine.apply(quarantine, dest: dest, tops: tops, since: started)
                DispatchQueue.main.async { finish(r) }
            }
        }
    }

    // MARK: Test

    static func test(info: ArchiveInfo, password: String?, host: NSWindow?, completion: @escaping (Bool, String?) -> Void) {
        var pw = password
        if info.hasEncryptedFiles, pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        runTest(info: info, password: pw, host: host, completion: completion)
    }

    private static func runTest(info: ArchiveInfo, password: String?, host: NSWindow?, completion: @escaping (Bool, String?) -> Void) {
        let stages: [Stage]
        if info.tarCompressed {
            stages = [(.sevenZip, ["x", "-so", RarRunner.passwordArg7z(password), "--", info.path]),
                      (.sevenZip, ["t", "-si", "-ttar", "-bb1"])]
        } else {
            stages = [(.sevenZip, ["t", "-bsp1", "-bb1", RarRunner.passwordArg7z(password), "--", info.path])]
        }
        runJob(title: LF("Test ediliyor: %@", name(info.path)), stages: stages, host: host, totalFiles: info.entries.count) { r in
            if r.cancelled { completion(false, password); return }
            if r.wrongPassword {
                guard let pw = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, password); return }
                runTest(info: info, password: pw, host: host, completion: completion)
                return
            }
            if r.ok {
                Dialogs.info(L("Test başarılı"), LF("\"%@\" arşivinde hata bulunmadı.", name(info.path)))
            } else {
                Dialogs.error(L("Test başarısız"), r.errorSummary, details: r.output)
            }
            completion(r.ok, password)
        }
    }

    // MARK: Sıkıştırma

    static func compress(items: [String], options: CompressOptions, host: NSWindow?, completion: @escaping (Bool, String) -> Void) {
        var o = options
        if o.format.isRar, !RarTools.ensureAvailable() { completion(false, o.archivePath); return }
        guard FolderAccess.ensure((o.archivePath as NSString).deletingLastPathComponent, write: true) else { completion(false, o.archivePath); return }
        func start() {
            let cwd = (o.archivePath as NSString).deletingLastPathComponent
            let steps = o.buildSteps(items: items)
            runSteps(steps, index: 0, archive: o.archivePath, cwd: cwd, host: host, completion: completion)
        }
        guard FileManager.default.fileExists(atPath: o.archivePath) else { start(); return }
        let alert = NSAlert()
        alert.messageText = LF("\"%@\" zaten var", name(o.archivePath))
        guard o.format.supportsAppend else {
            alert.informativeText = L("Bu biçimde mevcut arşive ekleme yapılamaz. Yeni bir arşiv oluşturulsun mu?")
            alert.addButton(withTitle: L("Yeni Arşiv Oluştur"))
            alert.addButton(withTitle: L("İptal"))
            Dialogs.activate()
            if alert.runModal() == .alertFirstButtonReturn { o.archivePath = uniquePath(o.archivePath); start() } else { completion(false, o.archivePath) }
            return
        }
        // Mevcut arşiv şifreli mi? (şifresiz listeleme denemesi; büyük arşivde uzun sürebilir: arka planda, iptal edilebilir)
        let probe = ListJob()
        let closePanel = delayedListPanel(o.archivePath, host: host, onCancel: { probe.cancel() })
        probe.start(o.archivePath, password: nil) { outcome in
            closePanel()
            guard let outcome else { completion(false, o.archivePath); return }   // iptal
            var existingEncrypted = false
            switch outcome {
            case .ok(let ex): existingEncrypted = ex.hasEncryptedFiles
            case .wrongPassword: existingEncrypted = true
            case .error: break
            }
            if existingEncrypted {
                alert.informativeText = L("Aynı adlı mevcut arşiv şifreli. Yeni, şifresiz bir arşiv oluşturulsun mu, yoksa dosyalar şifreli arşive mi eklensin?")
                alert.addButton(withTitle: L("Yeni Arşiv Oluştur"))
                alert.addButton(withTitle: L("Şifreli Arşive Ekle…"))
                alert.addButton(withTitle: L("İptal"))
                Dialogs.activate()
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    o.archivePath = uniquePath(o.archivePath)
                    start()
                case .alertSecondButtonReturn:
                    let path = o.archivePath
                    list(archive: path, password: nil, showPanel: true, host: host) { existing, pw in
                        guard let existing else { completion(false, path); return }
                        add(info: existing, items: items, password: pw, host: host) { ok, _ in completion(ok, path) }
                    }
                default:
                    completion(false, o.archivePath)
                }
            } else {
                alert.informativeText = L("Yeni bir arşiv oluşturulsun mu, yoksa dosyalar mevcut arşive mi eklensin?")
                alert.addButton(withTitle: L("Yeni Arşiv Oluştur"))
                alert.addButton(withTitle: L("Mevcut Arşive Ekle"))
                alert.addButton(withTitle: L("İptal"))
                Dialogs.activate()
                switch alert.runModal() {
                case .alertFirstButtonReturn: o.archivePath = uniquePath(o.archivePath); start()
                case .alertSecondButtonReturn: start()
                default: completion(false, o.archivePath)
                }
            }
        }
    }

    private static func runSteps(_ steps: [CompressOptions.Step], index: Int, archive: String, cwd: String, warned: Bool = false,
                                 host: NSWindow?, completion: @escaping (Bool, String) -> Void) {
        guard index < steps.count else { completion(true, archive); return }
        let step = steps[index]
        let suffix = steps.count > 1 ? " (\(index + 1)/\(steps.count))" : ""
        runJob(title: "\(L(step.title)): \(name(archive))\(suffix)", tool: step.tool, args: step.args, cwd: cwd, host: host, totalFiles: nil) { r in
            step.cleanup?()
            if r.cancelled {
                steps[(index + 1)...].forEach { $0.cleanup?() }
                completion(false, archive); return
            }
            if !r.ok {
                steps[(index + 1)...].forEach { $0.cleanup?() }
                Dialogs.error(L("Sıkıştırma başarısız"), r.errorSummary, details: r.output)
                completion(false, archive)
                return
            }
            let warned = warned || r.code != 0
            if !step.deleteOnSuccess.isEmpty { deleteSources(step.deleteOnSuccess, warned: warned) }
            runSteps(steps, index: index + 1, archive: archive, cwd: cwd, warned: warned, host: host, completion: completion)
        }
    }

    /// Çok adımlı sıkıştırmada (tar.gz vb.) kaynakları yalnızca tüm adımlar bitince çöpe taşır.
    /// Uyarı varsa (okunamayan dosya gibi) arşivde eksik olabilir: kaynaklara dokunulmaz.
    private static func deleteSources(_ items: [String], warned: Bool) {
        if warned {
            Dialogs.info(L("Kaynak dosyalar silinmedi"), L("Sıkıştırma uyarılarla tamamlandığı için kaynak dosyalar yerinde bırakıldı."))
            return
        }
        var failed: [String] = []
        for item in items {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: item), resultingItemURL: nil) }
            catch { failed.append(name(item)) }
        }
        if !failed.isEmpty {
            Dialogs.error(L("Kaynak dosyalar silinemedi"), failed.prefix(8).joined(separator: "\n") + (failed.count > 8 ? "\n…" : ""))
        }
    }

    // MARK: Mevcut arşive dosya ekleme / silme

    static func add(info: ArchiveInfo, items: [String], password: String?, host: NSWindow?, completion: @escaping (Bool, String?) -> Void) {
        guard info.supportsModification else {
            Dialogs.error(L("Desteklenmiyor"), L("tar.gz / tar.xz türü arşivlere dosya eklenemez. Yeni bir arşiv oluşturun."))
            completion(false, password); return
        }
        if info.kind == .rar, !RarTools.ensureAvailable() { completion(false, password); return }
        guard FolderAccess.ensure((info.path as NSString).deletingLastPathComponent, write: true) else { completion(false, password); return }
        var pw = password
        if info.hasEncryptedFiles, pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        let stages: [Stage]
        switch info.kind {
        case .rar:
            stages = [(.rar, ["a", "-ep1", "-r", "-y"] + RarRunner.rarPasswordArgs(pw, encryptHeaders: info.headersEncrypted) + ["--", info.path] + items)]
        case .other:
            var args = ["a", "-y", "-bsp1", "-bb1", RarRunner.passwordArg7z(pw)]
            if info.headersEncrypted { args.append("-mhe=on") }
            stages = [(.sevenZip, args + ["--", info.path] + items)]
        }
        runJob(title: LF("Ekleniyor: %@", name(info.path)), stages: stages, host: host, totalFiles: nil) { r in
            if r.cancelled { completion(false, pw); return }
            if r.wrongPassword {
                guard let p = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, pw); return }
                add(info: info, items: items, password: p, host: host, completion: completion)
                return
            }
            if !r.ok { Dialogs.error(L("Ekleme başarısız"), r.errorSummary, details: r.output) }
            completion(r.ok, pw)
        }
    }

    static func delete(info: ArchiveInfo, names: [String], password: String?, host: NSWindow?, completion: @escaping (Bool, String?) -> Void) {
        guard info.supportsModification else {
            Dialogs.error(L("Desteklenmiyor"), L("tar.gz / tar.xz türü arşivlerden dosya silinemez."))
            completion(false, password); return
        }
        if info.kind == .rar, !RarTools.ensureAvailable() { completion(false, password); return }
        guard FolderAccess.ensure((info.path as NSString).deletingLastPathComponent, write: true) else { completion(false, password); return }
        var pw = password
        if info.headersEncrypted, pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        let stages: [Stage]
        switch info.kind {
        case .rar:
            stages = [(.rar, ["d", "-y"] + RarRunner.rarPasswordArgs(pw) + ["--", info.path] + names)]
        case .other:
            stages = [(.sevenZip, ["d", "-y", "-bsp1", "-bb1", RarRunner.passwordArg7z(pw), "--", info.path] + names)]
        }
        runJob(title: LF("Siliniyor: %@", name(info.path)), stages: stages, host: host, totalFiles: nil) { r in
            if r.cancelled { completion(false, pw); return }
            if r.wrongPassword {
                guard let p = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, pw); return }
                delete(info: info, names: names, password: p, host: host, completion: completion)
                return
            }
            if !r.ok { Dialogs.error(L("Silme başarısız"), r.errorSummary, details: r.output) }
            completion(r.ok, pw)
        }
    }

    // MARK: Hedef klasör yardımcıları

    static func folderNamedAfterArchive(_ archive: String) -> String {
        let ns = archive as NSString
        var base = (ns.deletingPathExtension as NSString).lastPathComponent
        // çok parçalı arşivlerde "ad.part1" → "ad", "ad.7z.001" → "ad"
        if let r = base.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) { base.removeSubrange(r) }
        if ns.pathExtension.range(of: #"^\d{3}$"#, options: .regularExpression) != nil {
            base = (base as NSString).deletingPathExtension
        }
        // ad.tar.gz → ad
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        return (ns.deletingLastPathComponent as NSString).appendingPathComponent(base)
    }

    /// Çıkartılacak üst düzey adlar (names nil → tüm arşiv)
    static func topLevelNames(info: ArchiveInfo, names: [String]?) -> [String] {
        guard let names else { return info.topLevelNames }
        var seen = Set<String>()
        return names.compactMap { n in
            let t = n.split(separator: "/", maxSplits: 1).first.map(String.init) ?? n
            return seen.insert(t).inserted ? t : nil
        }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Çıkartma sonrası: çıkan üst düzey öğeleri Finder'da seçer (yoksa hedef klasörü)
    static func revealExtracted(info: ArchiveInfo, names: [String]?, dest: String) {
        guard Prefs.revealAfterExtract else { return }
        let urls = topLevelNames(info: info, names: names).map { URL(fileURLWithPath: (dest as NSString).appendingPathComponent($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if urls.isEmpty { revealInFinder(dest) } else { NSWorkspace.shared.activateFileViewerSelecting(Array(urls.prefix(50))) }
    }
}
