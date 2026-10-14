import Foundation

private let items = ["/in/f1.txt", "/in/dir"]

private func opts(_ format: ArchiveFormat, path: String? = nil, _ configure: (inout CompressOptions) -> Void = { _ in }) -> CompressOptions {
    var o = CompressOptions(archivePath: path ?? "/out/a." + format.ext)
    o.format = format
    configure(&o)
    return o
}

func runCompressTests() {
    test("buildSteps 7z: şifre, ad şifreleme, düzey, parça, kaynak silme, katı") {
        let o = opts(.sevenZip) {
            $0.level = 5; $0.password = "pw"; $0.encryptNames = true; $0.volumeSize = "100M"; $0.deleteAfter = true; $0.solid = true
        }
        let steps = o.buildSteps(items: items)
        expectEqual(steps.count, 1)
        expect(steps[0].tool == .sevenZip)
        expectEqual(steps[0].args, ["a", "-y", "-bsp1", "-bb1", "-v100M", "-sdel", "-t7z", "-mx=9", "-ms=on", "-ppw", "-mhe=on",
                                    "--", "/out/a.7z", "/in/f1.txt", "/in/dir"])
        // şifresiz, katı değil: ne -p ne -mhe
        let plain = opts(.sevenZip) { $0.encryptNames = true }.buildSteps(items: items)[0].args
        expectEqual(plain, ["a", "-y", "-bsp1", "-bb1", "-t7z", "-mx=5", "-ms=off", "--", "/out/a.7z", "/in/f1.txt", "/in/dir"])
        expect(!plain.contains { $0.hasPrefix("-p") || $0 == "-mhe=on" }, "şifre yokken şifre anahtarı olmamalı")
        // boş şifre = şifre yok
        let empty = opts(.sevenZip) { $0.password = "" }.buildSteps(items: items)[0].args
        expect(!empty.contains { $0.hasPrefix("-p") })
        // boş parça boyutu eklenmez
        let noVol = opts(.sevenZip) { $0.volumeSize = "" }.buildSteps(items: items)[0].args
        expect(!noVol.contains { $0.hasPrefix("-v") })
    }

    test("buildSteps: sıkıştırma düzeyi -mx eşlemesi") {
        let expected = [0: 0, 1: 1, 2: 3, 3: 5, 4: 7, 5: 9, -3: 0, 99: 9]
        for (level, mx) in expected {
            let args = opts(.sevenZip) { $0.level = level }.buildSteps(items: items)[0].args
            expect(args.contains("-mx=\(mx)"), "düzey \(level) → -mx=\(mx), bulunan \(args)")
        }
    }

    test("buildSteps zip: AES256 şifre, parça, kaynak silme") {
        let o = opts(.zip) { $0.password = "s3cret"; $0.volumeSize = "1G"; $0.deleteAfter = true; $0.encryptNames = true }
        let args = o.buildSteps(items: items)[0].args
        expectEqual(args, ["a", "-y", "-bsp1", "-bb1", "-v1G", "-sdel", "-tzip", "-mx=5", "-ps3cret", "-mem=AES256",
                           "--", "/out/a.zip", "/in/f1.txt", "/in/dir"])
        expect(!args.contains("-mhe=on"), "zip'te ad şifreleme yok")
        let plain = opts(.zip).buildSteps(items: items)[0].args
        expectEqual(plain, ["a", "-y", "-bsp1", "-bb1", "-tzip", "-mx=5", "--", "/out/a.zip", "/in/f1.txt", "/in/dir"])
    }

    test("buildSteps tar: düzey/şifre/parça yok, -sdel var") {
        let o = opts(.tar) { $0.password = "pw"; $0.volumeSize = "10M"; $0.level = 5; $0.deleteAfter = true }
        let steps = o.buildSteps(items: items)
        expectEqual(steps.count, 1)
        expectEqual(steps[0].args, ["a", "-y", "-bsp1", "-bb1", "-sdel", "-ttar", "--", "/out/a.tar", "/in/f1.txt", "/in/dir"])
        expectEqual(steps[0].deleteOnSuccess, [])
        let plain = opts(.tar).buildSteps(items: items)[0].args
        expect(!plain.contains("-sdel"))
    }

    test("buildSteps tar.gz / tar.xz / tar.bz2: iki adım, -sdel 1. adımda yok") {
        let cases: [(ArchiveFormat, String, String)] = [(.tgz, "/out/a.tar.gz", "gzip"), (.txz, "/out/a.tar.xz", "xz"), (.tbz2, "/out/a.tar.bz2", "bzip2")]
        for (fmt, path, outer) in cases {
            let o = opts(fmt, path: path) { $0.deleteAfter = true; $0.level = 4; $0.password = "yok sayılır" }
            let steps = o.buildSteps(items: items)
            expectEqual(steps.count, 2, "\(fmt.ext) adım sayısı")
            if steps.count != 2 { continue }
            let s1 = steps[0].args, s2 = steps[1].args
            // 1. adım: yalnız tar paketle; -sdel olmamalı (iptal/başarısızlıkta kaynaklar kaybolurdu)
            expect(!s1.contains("-sdel"), "1. adımda -sdel olmamalı")
            expect(!s2.contains("-sdel"), "2. adımda da -sdel anahtarı olmamalı (silme uygulama tarafında)")
            expectEqual(Array(s1.prefix(5)), ["a", "-y", "-bsp1", "-bb1", "-ttar"])
            expectEqual(Array(s1.suffix(items.count)), items)
            expectEqual(s1[s1.count - items.count - 2], "--")
            let tmpTar = s1[s1.count - items.count - 1]
            expectEqual((tmpTar as NSString).lastPathComponent, "a.tar", "geçici tar adı arşivle aynı olmalı")
            // 2. adım: dış sıkıştırma tmpTar → arşiv
            expectEqual(s2, ["a", "-y", "-bsp1", "-bb1", "-t\(outer)", "-mx=7", "--", path, tmpTar])
            // kaynaklar yalnız son adımın başarısında silinir
            expectEqual(steps[0].deleteOnSuccess, [])
            expectEqual(steps[1].deleteOnSuccess, items)
            // geçici dizin oluşmuş ve son adımın temizliği onu siler
            let tmpDir = (tmpTar as NSString).deletingLastPathComponent
            expect(FileManager.default.fileExists(atPath: tmpDir), "geçici dizin oluşturulmalı")
            expect(steps[1].cleanup != nil, "temizlik kancası olmalı")
            steps[1].cleanup?()
            expect(!FileManager.default.fileExists(atPath: tmpDir), "cleanup geçici dizini silmeli")
        }
        // deleteAfter kapalıyken silinecek kaynak yok
        let off = opts(.tgz, path: "/out/a.tar.gz").buildSteps(items: items)
        expectEqual(off[1].deleteOnSuccess, [])
        off[1].cleanup?()
        TempDirs.cleanupAll()
    }

    test("buildSteps rar5: şifre yokken -p anahtarı yok") {
        let o = opts(.rar5)
        let s = o.buildSteps(items: items)
        expectEqual(s.count, 1)
        expect(s[0].tool == .rar)
        expectEqual(s[0].args, ["a", "-ep1", "-r", "-y", "-m3", "-ma5", "--", "/out/a.rar", "/in/f1.txt", "/in/dir"])
        // rar "-p-" ile "-" şifresini kullanır: hiçbir -p / -hp anahtarı olmamalı
        expect(!s[0].args.contains { $0.hasPrefix("-p") || $0.hasPrefix("-hp") })
        let empty = opts(.rar5) { $0.password = "" }.buildSteps(items: items)[0].args
        expect(!empty.contains { $0.hasPrefix("-p") || $0.hasPrefix("-hp") })
    }

    test("buildSteps rar5: şifre, ad şifreleme, katı, kurtarma, parça, SFX, kaynak silme") {
        let withPw = opts(.rar5) { $0.password = "pw" }.buildSteps(items: items)[0].args
        expect(withPw.contains("-ppw") && !withPw.contains("-hppw"))
        let hp = opts(.rar5) { $0.password = "pw"; $0.encryptNames = true }.buildSteps(items: items)[0].args
        expect(hp.contains("-hppw") && !hp.contains("-ppw"), "ad şifrelemede -hp kullanılmalı")
        // ad şifreleme şifre olmadan etkisiz
        let hpNoPw = opts(.rar5) { $0.encryptNames = true }.buildSteps(items: items)[0].args
        expect(!hpNoPw.contains { $0.hasPrefix("-hp") || $0.hasPrefix("-p") })
        let all = opts(.rar5) {
            $0.level = 5; $0.solid = true; $0.recoveryRecord = true; $0.volumeSize = "50M"; $0.sfx = true; $0.deleteAfter = true
        }.buildSteps(items: items)[0].args
        expectEqual(all, ["a", "-ep1", "-r", "-y", "-m5", "-ma5", "-s", "-rr3", "-v50M", "-sfx", "-df", "--", "/out/a.rar", "/in/f1.txt", "/in/dir"])
        // şifre, "--"den önce gelmeli (yoksa dosya adı sanılır)
        let idx = withPw.firstIndex(of: "-ppw") ?? Int.max
        let sep = withPw.firstIndex(of: "--") ?? -1
        expect(idx < sep, "-p, -- ayracından önce olmalı")
    }

    test("CompressOptions.defaultArchivePath") {
        let t = (NSTemporaryDirectory() as NSString).appendingPathComponent("macrar-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: t + "/klasor", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: t) }
        FileManager.default.createFile(atPath: t + "/belge.txt", contents: Data("x".utf8))
        expectEqual(CompressOptions.defaultArchivePath(for: [t + "/belge.txt"], format: .zip), t + "/belge.zip")
        expectEqual(CompressOptions.defaultArchivePath(for: [t + "/klasor"], format: .tgz), t + "/klasor.tar.gz")
        expectEqual(CompressOptions.defaultArchivePath(for: [t + "/belge.txt", t + "/klasor"], format: .sevenZip),
                    t + "/" + (t as NSString).lastPathComponent + ".7z")
        expectEqual(CompressOptions.defaultArchivePath(for: [], format: .zip), L("arşiv") + ".zip")
    }
}

func runProcessAndResultTests() {
    // MARK: makeProcess

    test("makeProcess: 7zz için -spd komuttan hemen sonra eklenir") {
        let p = RarRunner.makeProcess(.sevenZip, ["x", "-y", "-o/tmp/out", "--", "/tmp/a.zip"], cwd: nil)
        expectEqual(p.arguments ?? [], ["x", "-spd", "-y", "-o/tmp/out", "--", "/tmp/a.zip"])
        let l = RarRunner.makeProcess(.sevenZip, ["l", "-slt", "-p", "--", "/tmp/a.zip"], cwd: nil)
        expectEqual(l.arguments ?? [], ["l", "-spd", "-slt", "-p", "--", "/tmp/a.zip"])
        let single = RarRunner.makeProcess(.sevenZip, ["i"], cwd: nil)
        expectEqual(single.arguments ?? [], ["i", "-spd"])
        // komut yoksa eklenecek yer de yok
        expectEqual(RarRunner.makeProcess(.sevenZip, [], cwd: nil).arguments ?? ["x"], [])
        expect(p.executableURL?.lastPathComponent == "7zz")
    }

    test("makeProcess: rar için -spd eklenmez; ortam ve çalışma dizini") {
        let args = ["a", "-ep1", "--", "/tmp/a.rar", "/tmp/f"]
        let p = RarRunner.makeProcess(.rar, args, cwd: "/tmp")
        expectEqual(p.arguments ?? [], args)
        expect(!(p.arguments ?? []).contains("-spd"))
        expectEqual(p.currentDirectoryURL?.path ?? "", "/tmp")
        expectEqual(p.environment?["LANG"] ?? "", "en_US.UTF-8")
        expectEqual(p.environment?["LC_ALL"] ?? "", "en_US.UTF-8")
        // giriş boş cihazdan: etkileşimli parola sorusunda takılmaz
        expect((p.standardInput as? FileHandle) === FileHandle.nullDevice)
    }

    test("RarRunner parola argümanları") {
        expectEqual(RarRunner.passwordArg7z(nil), "-p")
        expectEqual(RarRunner.passwordArg7z(""), "-p")
        expectEqual(RarRunner.passwordArg7z("abc"), "-pabc")
        expectEqual(RarRunner.rarPasswordArgs(nil), [])
        expectEqual(RarRunner.rarPasswordArgs(""), [])
        expectEqual(RarRunner.rarPasswordArgs("abc"), ["-pabc"])
        expectEqual(RarRunner.rarPasswordArgs("abc", encryptHeaders: true), ["-hpabc"])
    }

    // MARK: RarResult

    test("RarResult.wrongPassword") {
        expect(RarResult(code: 11, output: "").wrongPassword, "çıkış kodu 11")
        expect(RarResult(code: 2, output: "ERROR: Wrong password : a.txt").wrongPassword)
        expect(RarResult(code: 2, output: "Cannot open encrypted archive. Wrong password?").wrongPassword)
        expect(RarResult(code: 3, output: "Incorrect password for a.txt").wrongPassword)
        expect(!RarResult(code: 0, output: "Everything is Ok").wrongPassword)
        expect(!RarResult(code: 2, output: "ERROR: Data Error : a.txt").wrongPassword)
        expect(!RarResult(code: 7, output: "").wrongPassword)
    }

    test("RarResult.notArchive ve ok") {
        expect(RarResult(code: 2, output: "x.bin is not RAR archive").notArchive)
        expect(RarResult(code: 2, output: "ERROR: Cannot open the file as archive").notArchive)
        expect(!RarResult(code: 2, output: "ERROR: Data Error").notArchive)
        expect(!RarResult(code: 0, output: "").notArchive)
        expect(RarResult(code: 0, output: "").ok)
        expect(RarResult(code: 1, output: "Warning").ok, "kod 1 = uyarı, başarılı sayılır")
        expect(!RarResult(code: 2, output: "").ok)
        expect(!RarResult(code: -1, output: "").ok)
    }

    test("RarResult.errorSummary") {
        let out = """
        7-Zip (z) 24.08 (arm64) : Copyright (c) 1999-2024 Igor Pavlov : 2024-08-11

        Scanning the drive for archives:
        1 file, 100 bytes

        Extracting archive: a.zip
        --
        Path = a.zip
        Type = zip

        ERROR: Data Error : a.txt
        Sub items Errors: 1
        Archives with Errors: 1
        """
        expectEqual(RarResult(code: 2, output: out).errorSummary, "ERROR: Data Error : a.txt\nSub items Errors: 1\nArchives with Errors: 1")
        // geri-silme karakterleri ve baştaki/sondaki boşluklar temizlenir; RAR başlık satırları atılır
        let rar = "RAR 5.00 beta\n  Cannot open\u{8}\u{8} file.rar  \n"
        expectEqual(RarResult(code: 2, output: rar).errorSummary, "Cannot open file.rar")
        // ilginç satır yoksa son 6 satır
        let plain = (1...10).map { "satir \($0)" }.joined(separator: "\n")
        expectEqual(RarResult(code: 2, output: plain).errorSummary, (5...10).map { "satir \($0)" }.joined(separator: "\n"))
        // çok sayıda hata satırında son 8
        let many = (1...12).map { "ERROR: dosya \($0)" }.joined(separator: "\n")
        expectEqual(RarResult(code: 2, output: many).errorSummary, (5...12).map { "ERROR: dosya \($0)" }.joined(separator: "\n"))
        expectEqual(RarResult(code: 2, output: "").errorSummary, "")
    }
}
