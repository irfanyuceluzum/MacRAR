#if !APPSTORE
import AppKit

/// GitHub Releases üzerinden yeni sürüm denetimi (anonim API, kimlik bilgisi yok).
enum UpdateChecker {
    static let defaultRepo = "mstcvk/MacRAR"
    /// Sürümlerin arandığı GitHub deposu ("sahip/ad"). Bir fork kendi sürümlerini dağıtacaksa derlerken
    /// MACRAR_UPDATE_REPO=sahip/ad ./build.sh ile Info.plist'e (MacRARUpdateRepo) yazılır.
    static let repo: String = {
        if let r = Bundle.main.object(forInfoDictionaryKey: "MacRARUpdateRepo") as? String, isValidRepo(r) { return r }
        return defaultRepo
    }()
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    /// Yalnız "sahip/ad" biçimi: URL'ye eklenen değerden başka bir adres çıkmasın
    static func isValidRepo(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil
            && !s.hasSuffix("/.") && !s.hasSuffix("/..")
    }
    private static let lastCheckKey = "UpdateLastCheck"
    private static let skipKey = "UpdateSkippedVersion"
    private static let interval: TimeInterval = 24 * 3600

    static var currentVersion: String {
        if let v = DebugHooks.env("MACRAR_DEBUG_VERSION") { return v }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Uygulama açılışında: günde en fazla bir kez, sessizce.
    static func checkAutomatically() {
        if ProcessInfo.processInfo.environment["MACRAR_NO_UPDATE_CHECK"] != nil { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        if Date().timeIntervalSince1970 - last < interval { return }
        check(manual: false)
    }

    /// Menüden: sonucu her durumda bildirir.
    static func check(manual: Bool) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacRAR/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                // 404: depoda henüz yayımlanmış sürüm yok (ör. yeni bir fork); bağlantı hatası değil
                if error == nil, (response as? HTTPURLResponse)?.statusCode == 404 {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                    if manual { Dialogs.info(L("Yayımlanmış sürüm yok"), LF("%@ deposunda henüz yayımlanmış bir sürüm bulunmuyor.", repo)) }
                    return
                }
                guard error == nil, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if manual { Dialogs.error(L("Güncelleme denetlenemedi"), L("GitHub'a ulaşılamadı. İnternet bağlantınızı kontrol edin.")) }
                    return
                }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage
                // "İndir" doğrudan DMG'yi indirsin; yoksa sürüm sayfası
                let assets = (json["assets"] as? [[String: Any]]) ?? []
                let dmgURL = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
                    .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
                let notes = (json["body"] as? String) ?? ""
                if isNewer(latest, than: currentVersion) {
                    if !manual, UserDefaults.standard.string(forKey: skipKey) == latest { return }
                    let show = { present(latest: latest, page: dmgURL ?? pageURL, notes: notes) }
                    // Otomatik denetimde açık bir soru/işlem varsa bitmesini bekle
                    if manual { show() } else { Dialogs.whenIdle(show) }
                } else if manual {
                    Dialogs.info(L("Güncel sürümü kullanıyorsunuz"), LF("MacRAR %@ en son sürüm.", currentVersion))
                }
            }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func present(latest: String, page: URL, notes: String) {
        Dialogs.activate()
        let alert = NSAlert()
        alert.messageText = LF("MacRAR %@ sürümü çıktı", latest)
        var info = LF("Kullandığınız sürüm: %@. Yeni sürümü GitHub'dan indirip Uygulamalar klasörüne sürükleyerek güncelleyebilirsiniz.", currentVersion)
        // Markdown işaretlerini sadeleştir, ilk satırları göster
        let lines = notes.components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") { l.removeFirst() }
            l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if l.hasPrefix("- ") { l = "• " + l.dropFirst(2) }
            return l.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if !lines.isEmpty {
            let shown = lines.prefix(7)
            info += "\n\n" + shown.joined(separator: "\n") + (lines.count > shown.count ? "\n…" : "")
        }
        alert.informativeText = info
        alert.addButton(withTitle: L("İndir"))
        alert.addButton(withTitle: L("Daha Sonra"))
        alert.addButton(withTitle: L("Bu Sürümü Atla"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(page)
        case .alertThirdButtonReturn: UserDefaults.standard.set(latest, forKey: skipKey)
        default: break
        }
    }
}

#endif
