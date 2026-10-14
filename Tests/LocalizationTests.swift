import Foundation

/// Swift dizgi sabitinin kaçışlarını çözer (\" \\ \n \t \r \0 \u{..}); yorumlanamayan kaçış varsa nil
private func unescapeSwiftLiteral(_ s: String) -> String? {
    var out = ""
    var it = s.makeIterator()
    while let c = it.next() {
        guard c == "\\" else { out.append(c); continue }
        guard let n = it.next() else { return nil }
        switch n {
        case "\"": out.append("\"")
        case "\\": out.append("\\")
        case "n": out.append("\n")
        case "t": out.append("\t")
        case "r": out.append("\r")
        case "0": out.append("\0")
        case "'": out.append("'")
        case "u":
            guard it.next() == "{" else { return nil }
            var hex = ""
            while let h = it.next(), h != "}" { hex.append(h) }
            guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else { return nil }
            out.unicodeScalars.append(sc)
        default: return nil   // "\(" enterpolasyon dahil
        }
    }
    return out
}

/// Kaynak metinden L("…") ve LF("… anahtarlarını çıkarır (kaçışlı tırnaklar dahil); // yorum satırları atlanır
func extractLocalizationKeys(from source: String) -> [String] {
    let code = source.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    var keys: [String] = []
    for fn in ["L", "LF"] {
        let pattern = #"(?<![A-Za-z0-9_])"# + fn + #"\("((?:[^"\\]|\\.)*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
        let ns = code as NSString
        for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
            if let k = unescapeSwiftLiteral(raw) { keys.append(k) }   // enterpolasyonlu anahtarlar çevrilemez, atlanır
        }
    }
    return keys
}

func runLocalizationTests() {
    test("L10n: İngilizce tablo yüklenir (yinelenen anahtar çökertir) ve boş değer yok") {
        let table = L10n.en
        expect(table.count > 100, "tablo beklenenden küçük: \(table.count)")
        for (k, v) in table where v.isEmpty { expect(false, "boş çeviri: \(k)") }
    }

    test("L/LF: anahtar bulma yardımcısı kaçışlı tırnakları doğru okur") {
        let src = """
        let a = L("Düz")
        let b = LF("\\"%@\\" arşivi\\nşifreli", x)
        let c = L("\\(x) enterpolasyonlu")
        // L("yorumdaki")
        let d = NSLocalizedString("yok", comment: "")
        let e = HELL("yok")
        """
        expectEqual(extractLocalizationKeys(from: src), ["Düz", "\"%@\" arşivi\nşifreli"])
    }

    test("Çeviri denetimi: Sources içindeki tüm L(\"…\") / LF(\"…\" anahtarları İngilizce tabloda var") {
        let dir = ProcessInfo.processInfo.environment["MACRAR_SOURCES_DIR"] ?? "Sources"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            expect(false, "Sources klasörü okunamadı: \(dir)"); return
        }
        var checked = 0
        var missing: [String] = []
        for f in files.sorted() where f.hasSuffix(".swift") {
            guard let text = try? String(contentsOfFile: (dir as NSString).appendingPathComponent(f), encoding: .utf8) else {
                expect(false, "\(f) okunamadı"); continue
            }
            for k in extractLocalizationKeys(from: text) {
                checked += 1
                if L10n.en[k] == nil { missing.append("\(f): \(k.replacingOccurrences(of: "\n", with: "\\n"))") }
            }
        }
        expect(checked > 100, "çok az anahtar bulundu (\(checked)); düzenli ifade bozulmuş olabilir")
        for m in missing { print("  eksik çeviri → \(m)") }
        expect(missing.isEmpty, "\(missing.count) anahtar L10n.en tablosunda yok")
    }

    test("L: dile göre anahtar ya da İngilizce karşılık döner") {
        let key = "Tamam"
        if L10n.isTurkish { expectEqual(L(key), "Tamam") } else { expectEqual(L(key), L10n.en[key] ?? "?") }
        // tabloda olmayan anahtar olduğu gibi döner
        expectEqual(L("tabloda-yok-xyz"), "tabloda-yok-xyz")
        expectEqual(LF("%d dosya", 3), String(format: L("%d dosya"), 3))
    }
}
