import Foundation

/// Her çağrıda yeni bir geçici dizin oluşturur; iş bitince `cleanup` ile silin
private func makeTempRoot() -> String {
    let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("macrar-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

private func touch(_ path: String) {
    FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
}

func runPathTests() {
    // MARK: dedupeVolumes

    test("dedupeVolumes: ad.part1.rar / part2.rar") {
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.part1.rar", "/d/a.part2.rar", "/d/a.part3.rar"]), ["/d/a.part1.rar"])
        // ilk parça seçimin sonunda olsa da yine ilk parça kalır
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.part3.rar", "/d/a.part2.rar", "/d/a.part1.rar"]), ["/d/a.part1.rar"])
        // sıfır dolgulu numaralar
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.part02.rar", "/d/a.part01.rar"]), ["/d/a.part01.rar"])
        // yalnız sonraki parça seçildiyse o kalır (ilk parça seçimde yok)
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.part2.rar"]), ["/d/a.part2.rar"])
    }

    test("dedupeVolumes: ad.7z.001 / .002") {
        expectEqual(AppDelegate.dedupeVolumes(["/d/b.7z.002", "/d/b.7z.001", "/d/b.7z.003"]), ["/d/b.7z.001"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/c.zip.001", "/d/c.zip.002"]), ["/d/c.zip.001"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/c.tar.002", "/d/c.tar.001"]), ["/d/c.tar.001"])
    }

    test("dedupeVolumes: ad.rar + ad.r00 / ad.r01") {
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.rar", "/d/a.r00", "/d/a.r01"]), ["/d/a.rar"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.r00", "/d/a.rar"]), ["/d/a.rar"])
        // ana .rar seçimde yoksa r00 olduğu gibi kalır
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.r00"]), ["/d/a.r00"])
        // başka adlı arşivin .rar dosyası bu parçayı elemez
        expectEqual(AppDelegate.dedupeVolumes(["/d/other.rar", "/d/a.r00"]), ["/d/other.rar", "/d/a.r00"])
    }

    test("dedupeVolumes: ad.zip + ad.z01") {
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.zip", "/d/a.z01", "/d/a.z02"]), ["/d/a.zip"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.z01"]), ["/d/a.z01"])
        // zip'in .rar'la karışmaması
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.rar", "/d/a.z01"]), ["/d/a.rar", "/d/a.z01"])
    }

    test("dedupeVolumes: karışık seçim, sıra ve farklı klasörler") {
        let input = ["/d/solo.zip", "/d/a.part2.rar", "/d/b.7z.001", "/d/a.part1.rar", "/d/b.7z.002", "/d/x.rar", "/d/x.r00"]
        // parçalı olmayanlar önce (girdi sırasıyla), sonra parça grupları ilk görülme sırasıyla
        expectEqual(AppDelegate.dedupeVolumes(input), ["/d/solo.zip", "/d/x.rar", "/d/a.part1.rar", "/d/b.7z.001"])
        // aynı ad, farklı klasör = farklı arşiv
        expectEqual(AppDelegate.dedupeVolumes(["/x/a.part1.rar", "/y/a.part1.rar", "/x/a.part2.rar"]),
                    ["/x/a.part1.rar", "/y/a.part1.rar"])
        expectEqual(AppDelegate.dedupeVolumes([]), [])
        expectEqual(AppDelegate.dedupeVolumes(["/d/n.txt", "/d/m.zip"]), ["/d/n.txt", "/d/m.zip"])
    }

    test("dedupeVolumes: büyük/küçük harf") {
        expectEqual(AppDelegate.dedupeVolumes(["/d/A.PART2.RAR", "/d/A.Part1.Rar"]), ["/d/A.Part1.Rar"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/B.7Z.002", "/d/B.7Z.001"]), ["/d/B.7Z.001"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/A.RAR", "/d/A.R00"]), ["/d/A.RAR"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/a.rar", "/d/A.R00"]), ["/d/a.rar"])
        expectEqual(AppDelegate.dedupeVolumes(["/d/A.ZIP", "/d/a.Z01"]), ["/d/A.ZIP"])
    }

    // MARK: Ops.folderNamedAfterArchive

    test("folderNamedAfterArchive: uzantılar ve parça ekleri atılır") {
        let t = makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: t) }
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.zip"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.part01.rar"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.PART2.RAR"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.7z.001"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.tar.gz"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/AD.TAR.XZ"), t + "/AD")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.tgz"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.tar"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/proje v1.2.zip"), t + "/proje v1.2")
    }

    test("folderNamedAfterArchive: uzantısız arşiv ve aynı adlı dosya") {
        let t = makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: t) }
        // uzantısız arşivin kendisi "ad": klasör aynı yolu alamaz → "ad 2"
        touch(t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad"), t + "/ad 2")
        // "ad 2" de doluysa "ad 3"
        touch(t + "/ad 2")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad"), t + "/ad 3")
        // ad.zip yanında "ad" adlı bir dosya varsa
        let u = makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: u) }
        touch(u + "/rapor")
        touch(u + "/rapor.zip")
        expectEqual(Ops.folderNamedAfterArchive(u + "/rapor.zip"), u + "/rapor 2")
    }

    test("folderNamedAfterArchive: aynı adlı klasör varsa klasörün kendisi") {
        let t = makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: t) }
        try? FileManager.default.createDirectory(atPath: t + "/ad", withIntermediateDirectories: true)
        touch(t + "/ad.zip")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.zip"), t + "/ad")
        // çok parçalı ve tar.gz için de
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.7z.001"), t + "/ad")
        expectEqual(Ops.folderNamedAfterArchive(t + "/ad.tar.gz"), t + "/ad")
    }

    // MARK: ArchiveFormat

    test("ArchiveFormat.detect") {
        expect(ArchiveFormat.detect(fromPath: "/p/a.tar.gz") == .tgz)
        expect(ArchiveFormat.detect(fromPath: "/p/a.tgz") == .tgz)
        expect(ArchiveFormat.detect(fromPath: "/p/a.TAR.GZ") == .tgz)
        expect(ArchiveFormat.detect(fromPath: "/p/a.tar.xz") == .txz)
        expect(ArchiveFormat.detect(fromPath: "/p/a.txz") == .txz)
        expect(ArchiveFormat.detect(fromPath: "/p/a.tar.bz2") == .tbz2)
        expect(ArchiveFormat.detect(fromPath: "/p/a.tbz2") == .tbz2)
        expect(ArchiveFormat.detect(fromPath: "/p/a.tbz") == .tbz2)
        expect(ArchiveFormat.detect(fromPath: "/p/a.rar") == .rar5)
        expect(ArchiveFormat.detect(fromPath: "/p/a.RAR") == .rar5)
        expect(ArchiveFormat.detect(fromPath: "/p/a.7z") == .sevenZip)
        expect(ArchiveFormat.detect(fromPath: "/p/a.zip") == .zip)
        expect(ArchiveFormat.detect(fromPath: "/p/a.tar") == .tar)
        expect(ArchiveFormat.detect(fromPath: "/p/a.tar.zip") == .zip)
        expect(ArchiveFormat.detect(fromPath: "/p/a.gz") == nil, "tek başına .gz bir oluşturma biçimi değil")
        expect(ArchiveFormat.detect(fromPath: "/p/a.txt") == nil)
        expect(ArchiveFormat.detect(fromPath: "/p/a") == nil)
        expect(ArchiveFormat.detect(fromPath: "") == nil)
    }

    test("ArchiveFormat.replacingExtension") {
        expectEqual(ArchiveFormat.tgz.replacingExtension(in: "/p/a.zip"), "/p/a.tar.gz")
        expectEqual(ArchiveFormat.zip.replacingExtension(in: "/p/a.tar.gz"), "/p/a.zip")
        expectEqual(ArchiveFormat.sevenZip.replacingExtension(in: "/p/a.TAR.GZ"), "/p/a.7z")
        expectEqual(ArchiveFormat.rar5.replacingExtension(in: "/p/a"), "/p/a.rar")
        expectEqual(ArchiveFormat.tar.replacingExtension(in: "/p/a.tbz"), "/p/a.tar")
        expectEqual(ArchiveFormat.txz.replacingExtension(in: "/p/a.tar.bz2"), "/p/a.tar.xz")
        expectEqual(ArchiveFormat.sevenZip.replacingExtension(in: "/p/a.b.zip"), "/p/a.b.7z")
        expectEqual(ArchiveFormat.zip.replacingExtension(in: "/p/a.zip"), "/p/a.zip")
        // bilinmeyen uzantı korunur, yenisi eklenir
        expectEqual(ArchiveFormat.zip.replacingExtension(in: "/p/a.docx"), "/p/a.docx.zip")
        expectEqual(ArchiveFormat.tbz2.replacingExtension(in: "/p/a.tgz"), "/p/a.tar.bz2")
    }

    test("ArchiveFormat: yetenek bayrakları") {
        expect(ArchiveFormat.tar.supportsAppend)
        expect(!ArchiveFormat.tgz.supportsAppend, "tar.gz'ye ekleme yapılamaz")
        expect(!ArchiveFormat.tar.supportsPassword)
        expect(ArchiveFormat.zip.supportsPassword && !ArchiveFormat.zip.supportsEncryptNames)
        expect(ArchiveFormat.sevenZip.supportsEncryptNames)
        expect(!ArchiveFormat.tar.supportsLevel && ArchiveFormat.tgz.supportsLevel)
    }

    // MARK: UpdateChecker.isNewer

    #if !APPSTORE
    test("UpdateChecker.isNewer") {
        expect(UpdateChecker.isNewer("1.10", than: "1.9"), "1.10 > 1.9 (sayısal karşılaştırma)")
        expect(!UpdateChecker.isNewer("1.9", than: "1.10"))
        expect(!UpdateChecker.isNewer("1.2", than: "1.2"))
        expect(UpdateChecker.isNewer("1.2.1", than: "1.2"))
        expect(!UpdateChecker.isNewer("1.2", than: "1.2.1"))
        expect(!UpdateChecker.isNewer("1.2", than: "1.2.0"), "eksik bileşen 0 sayılır")
        expect(!UpdateChecker.isNewer("1.2.0", than: "1.2"))
        expect(UpdateChecker.isNewer("2", than: "1.9.9"))
        expect(UpdateChecker.isNewer("1.3", than: "1.2.9"))
        expect(!UpdateChecker.isNewer("1.2.9", than: "1.3"))
        expect(UpdateChecker.isNewer("0.1", than: "0"))
        expect(!UpdateChecker.isNewer("", than: "1.0"))
    }

    test("UpdateChecker.isValidRepo / varsayılan depo") {
        expect(UpdateChecker.isValidRepo("mstcvk/MacRAR"))
        expect(UpdateChecker.isValidRepo("irfanyuceluzum/MacRAR"))
        expect(UpdateChecker.isValidRepo("a-b/repo.name_1"))
        expect(!UpdateChecker.isValidRepo("MacRAR"), "sahip yok")
        expect(!UpdateChecker.isValidRepo("a/b/c"), "fazla bileşen")
        expect(!UpdateChecker.isValidRepo("../x"))
        expect(!UpdateChecker.isValidRepo("a/.."))
        expect(!UpdateChecker.isValidRepo("evil.com/x"), "sahipte nokta olamaz")
        expect(!UpdateChecker.isValidRepo("a/b?x=1"))
        expect(!UpdateChecker.isValidRepo("a /b"))
        // Test ikilisinin Info.plist'i yok: varsayılan depo kullanılır
        expectEqual(UpdateChecker.repo, UpdateChecker.defaultRepo)
        expectEqual(UpdateChecker.releasesPage.absoluteString, "https://github.com/mstcvk/MacRAR/releases/latest")
    }
    #endif
}
