import Foundation

// `7zz l -slt` çıktısı biçiminde elle yazılmış örnekler

private let zipListing = """
7-Zip (z) 24.08 (arm64) : Copyright (c) 1999-2024 Igor Pavlov : 2024-08-11

Scanning the drive for archives:
1 file, 812 bytes (1 KiB)

Listing archive: /tmp/a.zip

--
Path = /tmp/a.zip
Type = zip
Physical Size = 812

----------
Path = readme.txt
Folder = -
Size = 100
Packed Size = 50
Modified = 2024-03-05 12:34:56.1234567
Created =
Accessed =
Attributes = A -rw-r--r--
Encrypted = -
Comment =
CRC = 0A1B2C3D
Method = Deflate
Host OS = Unix

Path = src
Folder = +
Size = 0
Packed Size = 0
Modified = 2024-03-05 12:00:00
Attributes = D drwxr-xr-x
Encrypted = -
Method =

Path = src/main.swift
Folder = -
Size = 2000
Packed Size = 500
Modified = 2024-03-06 08:00:00
Attributes = A -rw-r--r--
Encrypted = -
CRC = FFFF0000
Method = Deflate

"""

private let sevenZipSolidListing = """
7-Zip (z) 24.08 (arm64) : Copyright (c) 1999-2024 Igor Pavlov : 2024-08-11

Listing archive: /tmp/a.7z

--
Path = /tmp/a.7z
Type = 7z
Physical Size = 400
Headers Size = 150
Method = LZMA2:12
Solid = +
Blocks = 1

----------
Path = a.txt
Size = 5
Packed Size = 20
Attributes = A
Encrypted = -
CRC = 11111111
Method = LZMA2:12

Path = klasor
Size = 0
Attributes = D
Encrypted = -

"""

private let encryptedListing = """
Listing archive: /tmp/e.zip

--
Path = /tmp/e.zip
Type = zip

----------
Path = gizli.txt
Folder = -
Size = 10
Packed Size = 22
Attributes = A
Encrypted = +
Method = ZipCrypto Deflate

Path = acik.txt
Folder = -
Size = 10
Packed Size = 10
Attributes = A
Encrypted = -
Method = Store

"""

private let traversalListing = """
Listing archive: /tmp/t.zip

--
Path = /tmp/t.zip
Type = zip

----------
Path = ../evil.txt
Folder = -
Size = 3
Attributes = A

Path = ..
Folder = +
Size = 0
Attributes = D

Path = a/../b.txt
Folder = -
Size = 4
Attributes = A

Path = /abs/c.txt
Folder = -
Size = 5
Attributes = A

Path = .
Folder = +
Attributes = D

Path = normal.txt
Folder = -
Size = 6
Attributes = A

Path = trailing/
Folder = +
Attributes = D

"""

private func rarListing(type: String, solid: Bool) -> String {
    """
    Listing archive: /tmp/r.rar

    --
    Path = /tmp/r.rar
    Type = \(type)
    Physical Size = 1000
    Solid = \(solid ? "+" : "-")

    ----------
    Path = f.bin
    Size = 100
    Packed Size = 90
    Attributes = A
    Encrypted = -
    CRC = 12345678
    Method = m3

    """
}

private func mkE(_ name: String) -> ArchiveEntry {
    ArchiveEntry(name: name, isDirectory: false)
}

func runListingTests() {
    test("parse7zListing: düz zip arşivi") {
        let info = RarRunner.parse7zListing(zipListing, path: "/tmp/a.zip")
        expectEqual(info.details, "ZIP")
        expectEqual(info.entries.count, 3)
        expectEqual(info.fileCount, 2)
        expect(!info.isSolid, "zip katı olmamalı")
        expect(!info.hasEncryptedFiles)
        expect(!info.tarCompressed)
        guard let f = info.entries.first else { expect(false, "girdi yok"); return }
        expectEqual(f.name, "readme.txt")
        expectEqual(f.rawName, "readme.txt")
        expectEqual(f.commandName, "readme.txt")
        expect(!f.isDirectory)
        expectEqual(f.size, 100)
        expectEqual(f.packedSize, 50)
        expectEqual(f.ratio, "50%")
        expectEqual(f.mtime, "2024-03-05 12:34:56")
        expectEqual(f.crc, "0A1B2C3D")
        expectEqual(f.compression, "Deflate")
        expectEqual(f.attributes, "A -rw-r--r--")
        expect(!f.encrypted)
        expectEqual(info.totalSize, 2100)
        expectEqual(info.totalPacked, 550)
    }

    test("parse7zListing: klasörlü arşiv, alt yol ve üst düzey adlar") {
        let info = RarRunner.parse7zListing(zipListing, path: "/tmp/a.zip")
        let dir = info.entries.first { $0.name == "src" }
        expect(dir?.isDirectory == true, "src klasör olmalı")
        let nested = info.entries.first { $0.name == "src/main.swift" }
        expect(nested != nil && nested?.isDirectory == false)
        expectEqual(nested?.displayName ?? "", "main.swift")
        expectEqual(nested?.parentPath ?? "", "src")
        expectEqual(info.topLevelNames, ["readme.txt", "src"])
    }

    test("parse7zListing: klasör yalnız Attributes D ile de anlaşılır, sondaki / atılır") {
        let info = RarRunner.parse7zListing(sevenZipSolidListing, path: "/tmp/a.7z")
        let d = info.entries.first { $0.name == "klasor" }
        expect(d?.isDirectory == true, "Folder satırı olmasa da D niteliği klasör sayılmalı")
        let t = RarRunner.parse7zListing(traversalListing, path: "/tmp/t.zip")
        let tr = t.entries.first { $0.name == "trailing" }
        expect(tr != nil, "sondaki / atılmış ad")
        expectEqual(tr?.rawName ?? "", "trailing")
        expect(tr?.isDirectory == true)
    }

    test("parse7zListing: 7z katı arşiv") {
        let info = RarRunner.parse7zListing(sevenZipSolidListing, path: "/tmp/a.7z")
        expectEqual(info.details, "7z, solid")
        expect(info.isSolid)
        let plain = sevenZipSolidListing.replacingOccurrences(of: "Solid = +", with: "Solid = -")
        let info2 = RarRunner.parse7zListing(plain, path: "/tmp/a.7z")
        expectEqual(info2.details, "7z")
        expect(!info2.isSolid)
        // eksik Size/Packed Size alanı 0 sayılır, oran boş kalır
        let d = info.entries.first { $0.name == "klasor" }
        expectEqual(d?.size ?? -1, 0)
        expectEqual(d?.ratio ?? "x", "")
    }

    test("parse7zListing: RAR 5 / RAR 4 ayrıntı metni") {
        let r5 = RarRunner.parse7zListing(rarListing(type: "Rar5", solid: true), path: "/tmp/r.rar", kind: .rar)
        expectEqual(r5.details, "RAR 5, solid")
        expect(r5.kind == .rar)
        let r5b = RarRunner.parse7zListing(rarListing(type: "Rar5", solid: false), path: "/tmp/r.rar", kind: .rar)
        expectEqual(r5b.details, "RAR 5")
        let r4 = RarRunner.parse7zListing(rarListing(type: "Rar", solid: false), path: "/tmp/r.rar", kind: .rar)
        expectEqual(r4.details, "RAR 4")
        expectEqual(r4.entries.first?.compression ?? "", "m3")
    }

    test("parse7zListing: parçalı arşivde dış Split türü değil asıl tür esas alınır") {
        let text = """
        Listing archive: /tmp/a.7z.001

        --
        Path = /tmp/a.7z.001
        Type = Split
        Volumes = 3
        Total Physical Size = 3000

        --
        Path = a.7z
        Type = 7z
        Solid = -

        ----------
        Path = x.bin
        Size = 1
        Attributes = A

        """
        let info = RarRunner.parse7zListing(text, path: "/tmp/a.7z.001")
        expectEqual(info.details, "7z, 3 volume")
        expectEqual(info.entries.count, 1)
    }

    test("parse7zListing: şifreli girdi") {
        let info = RarRunner.parse7zListing(encryptedListing, path: "/tmp/e.zip")
        expectEqual(info.entries.count, 2)
        expect(info.entries[0].encrypted, "Encrypted = + şifreli sayılmalı")
        expect(!info.entries[1].encrypted, "Encrypted = - şifresiz")
        expect(info.hasEncryptedFiles)
        expectEqual(info.entries.filter { $0.encrypted }.count, 1)
        // hiç şifreli girdi yoksa
        let none = RarRunner.parse7zListing(zipListing, path: "/tmp/a.zip")
        expect(!none.hasEncryptedFiles)
    }

    test("parse7zListing: tar.gz / tgz yolu") {
        let inner = """
        Listing archive:

        --
        Path =
        Type = tar
        Physical Size = 10240

        ----------
        Path = proje/dosya.txt
        Size = 12
        Attributes = A -rw-r--r--

        Path = proje
        Folder = +
        Size = 0
        Attributes = D drwxr-xr-x

        """
        let info = RarRunner.parse7zListing(inner, path: "/tmp/a.tar.gz")
        expectEqual(info.details, "tar + gz")
        expect(info.tarCompressed)
        expect(!info.supportsModification, "tar.gz'ye ekleme/silme desteklenmez")
        expectEqual(info.entries.count, 2)
        let tgz = RarRunner.parse7zListing(inner, path: "/tmp/a.tgz")
        expectEqual(tgz.details, "tar + tgz")
        // Tür satırı hiç yoksa bile tar.gz yolunda ayrıntı metni "tar + uzantı" olur
        let bare = RarRunner.parse7zListing("----------\nPath = x\nSize = 1\n", path: "/tmp/b.tar.xz")
        expectEqual(bare.details, "tar + xz")
        // sıradan arşiv tar sayılmaz
        expect(!RarRunner.parse7zListing(zipListing, path: "/tmp/a.zip").tarCompressed)
    }

    test("parse7zListing: yol aşımı (traversal) girdileri") {
        let info = RarRunner.parse7zListing(traversalListing, path: "/tmp/t.zip")
        // ".." ve "." girdileri atlanır; geriye evil, a/b, abs/c, normal, trailing kalır
        expectEqual(info.entries.map { $0.name }, ["evil.txt", "a/b.txt", "abs/c.txt", "normal.txt", "trailing"])
        let evil = info.entries[0]
        expectEqual(evil.name, "evil.txt")
        expectEqual(evil.rawName, "../evil.txt")
        expectEqual(evil.commandName, "../evil.txt")
        expectEqual(evil.displayName, "evil.txt")
        let mid = info.entries[1]
        expectEqual(mid.rawName, "a/../b.txt")
        expectEqual(mid.commandName, "a/../b.txt")
        let abs = info.entries[2]
        expectEqual(abs.name, "abs/c.txt")
        expectEqual(abs.rawName, "/abs/c.txt")
        // normal girdide komut adı = ad
        let normal = info.entries[3]
        expectEqual(normal.commandName, "normal.txt")
        // hiçbir arındırılmış ad ".." bileşeni taşımaz ya da / ile başlamaz
        for e in info.entries {
            expect(!e.name.hasPrefix("/"), "\(e.name) / ile başlıyor")
            expect(!e.name.split(separator: "/").contains(".."), "\(e.name) .. içeriyor")
        }
        expectEqual(info.topLevelNames, ["evil.txt", "a", "abs", "normal.txt", "trailing"])
    }

    test("parse7zListing: ayrıştırılamayan çıktı") {
        let info = RarRunner.parse7zListing("tamamen alakasız metin", path: "/tmp/x.zip")
        expectEqual(info.entries.count, 0)
        expectEqual(info.details, L("arşiv"))
        expectEqual(info.totalSize, 0)
    }

    test("ArchiveEntry.sanitize") {
        expectEqual(ArchiveEntry.sanitize("a/b/c.txt"), "a/b/c.txt")
        expectEqual(ArchiveEntry.sanitize("../evil.txt"), "evil.txt")
        expectEqual(ArchiveEntry.sanitize("../../x/../y"), "x/y")
        expectEqual(ArchiveEntry.sanitize("/abs/x"), "abs/x")
        expectEqual(ArchiveEntry.sanitize("a/./b"), "a/b")
        expectEqual(ArchiveEntry.sanitize("a//b"), "a/b")
        expectEqual(ArchiveEntry.sanitize("a/.."), "a")
        expectEqual(ArchiveEntry.sanitize(".."), "")
        expectEqual(ArchiveEntry.sanitize("."), "")
        expectEqual(ArchiveEntry.sanitize(""), "")
        expectEqual(ArchiveEntry.sanitize("/"), "")
        expectEqual(ArchiveEntry.sanitize("..hidden/.x"), "..hidden/.x")   // yalnız tam ".." bileşeni atılır
    }

    test("ArchiveInfo.topLevelNames: .. / . / boş ad dönmez, tekrarlar atılır") {
        var info = ArchiveInfo(path: "/tmp/x.zip", kind: .other, details: "", entries: [])
        info.entries = [mkE(".."), mkE("."), mkE(""), mkE("/"), mkE("../x/y"), mkE("a/b"), mkE("a/c"), mkE("b"), mkE("./c/d")]
        // ham (arındırılmamış) adlar verilse bile ".." / "." / boş ad dönmez
        let tops = info.topLevelNames
        expect(!tops.contains(".."), "\"..\" dönmemeli")
        expect(!tops.contains("."), "\".\" dönmemeli")
        expect(!tops.contains(""), "boş ad dönmemeli")
        expectEqual(tops, ["a", "b"])   // sıra: ilk görülme; "../x/y" ve "./c/d" ilk bileşenleri yüzünden atlanır
        info.entries = [mkE("z"), mkE("a/1"), mkE("z/2"), mkE("m")]
        expectEqual(info.topLevelNames, ["z", "a", "m"])
        info.entries = []
        expectEqual(info.topLevelNames, [])
    }
}
