import Foundation

private func mk(_ name: String, dir: Bool = false, size: Int64 = 0, packed: Int64 = 0, enc: Bool = false, raw: String = "") -> ArchiveEntry {
    ArchiveEntry(name: name, rawName: raw, isDirectory: dir, size: size, packedSize: packed, encrypted: enc)
}

private func nodeAt(_ root: Node, _ path: String) -> Node? {
    var cur = root
    for part in path.split(separator: "/") {
        guard let c = cur.children.first(where: { $0.name == part }) else { return nil }
        cur = c
    }
    return cur
}

func runTreeTests() {
    let entries = [
        mk("z.txt", size: 5, packed: 5),
        mk("docs/a.txt", size: 10, packed: 4),
        mk("docs/sub/b.txt", size: 20, packed: 8, enc: true),
        mk("alpha", dir: true),
        mk("alpha/x.bin", size: 1, packed: 1),
        mk("docs", dir: true),
        mk("b.txt", size: 7, packed: 3),
    ]

    test("Node.buildTree: klasör toplamları ve şifreli işareti") {
        let root = Node.buildTree(entries)
        let docs = nodeAt(root, "docs")
        expect(docs?.isDir == true)
        expectEqual(docs?.totalSize ?? -1, 30)
        expectEqual(docs?.totalPacked ?? -1, 12)
        expect(docs?.containsEncrypted == true, "alt ağaçtaki şifreli dosya klasöre yansımalı")
        // örtük (girdisi olmayan) ara klasör de toplam taşır
        let sub = nodeAt(root, "docs/sub")
        expect(sub?.isDir == true && sub?.entry == nil, "docs/sub arşivde ayrı girdi olmadan oluşturulur")
        expectEqual(sub?.totalSize ?? -1, 20)
        expect(sub?.containsEncrypted == true)
        let alpha = nodeAt(root, "alpha")
        expectEqual(alpha?.totalSize ?? -1, 1)
        expect(alpha?.containsEncrypted == false)
        expectEqual(root.totalSize, 43)
        expectEqual(root.totalPacked, 21)
        expect(root.containsEncrypted)
        // dosya düğümü kendi girdisinden
        let a = nodeAt(root, "docs/a.txt")
        expectEqual(a?.totalSize ?? -1, 10)
        expect(a?.isDir == false && a?.containsEncrypted == false)
        expect(a?.parent === docs)
        expectEqual(a?.path ?? "", "docs/a.txt")
    }

    test("Node.buildTree: sıralama (klasörler önce)") {
        let root = Node.buildTree(entries)
        expectEqual(root.children.map { $0.name }, ["alpha", "docs", "b.txt", "z.txt"])
        expectEqual(nodeAt(root, "docs")?.children.map { $0.name } ?? [], ["sub", "a.txt"])
        // boyuta göre azalan: klasörler yine önce, kendi aralarında toplam boyuta göre
        let bySizeDesc = Node.buildTree(entries, key: "size", ascending: false)
        expectEqual(bySizeDesc.children.map { $0.name }, ["docs", "alpha", "b.txt", "z.txt"])
        let bySizeAsc = Node.buildTree(entries, key: "size", ascending: true)
        expectEqual(bySizeAsc.children.map { $0.name }, ["alpha", "docs", "z.txt", "b.txt"])
        // ada göre azalan: klasörler yine önce
        let byNameDesc = Node.buildTree(entries, key: "name", ascending: false)
        expectEqual(byNameDesc.children.map { $0.name }, ["docs", "alpha", "z.txt", "b.txt"])
    }

    test("Node.commandPaths: normal alt ağaçta tek yol") {
        let root = Node.buildTree(entries)
        expectEqual(nodeAt(root, "docs")?.commandPaths() ?? [], ["docs"])
        expectEqual(nodeAt(root, "docs/sub")?.commandPaths() ?? [], ["docs/sub"])
        expectEqual(nodeAt(root, "docs/a.txt")?.commandPaths() ?? [], ["docs/a.txt"])
        expectEqual(nodeAt(root, "alpha")?.commandPaths() ?? [], ["alpha"])
    }

    test("Node.commandPaths: traversal içeren alt ağaçta ham adlar") {
        let e = [
            mk("d", dir: true),
            mk("d/evil.txt", size: 3, raw: "d/../evil.txt"),
            mk("d/ok.txt", size: 4, raw: "d/ok.txt"),
            mk("temiz", dir: true),
            mk("temiz/f.txt", size: 1, raw: "temiz/f.txt"),
            mk("kok.txt", size: 2, raw: "../kok.txt"),
        ]
        let root = Node.buildTree(e)
        // traversal içeren klasör: kendisi ve tüm alt girdilerin ham adları (klasörün tek başına çıkarılması yanlış dosyayı yazardı)
        let d = nodeAt(root, "d")
        expect(d?.containsTraversal == true)
        expectEqual((d?.commandPaths() ?? []).sorted(), ["d", "d/../evil.txt", "d/ok.txt"])
        // temiz kardeş klasör etkilenmez
        let temiz = nodeAt(root, "temiz")
        expect(temiz?.containsTraversal == false)
        expectEqual(temiz?.commandPaths() ?? [], ["temiz"])
        // traversal içeren tek dosya: ham ad
        let kok = nodeAt(root, "kok.txt")
        expectEqual(kok?.rawPath ?? "", "../kok.txt")
        expectEqual(kok?.commandPaths() ?? [], ["../kok.txt"])
        // kök de traversal içerir
        expect(root.containsTraversal)
        // ham adı olmayan girdide commandName = name
        let evil = nodeAt(root, "d/evil.txt")
        expectEqual(evil?.commandPaths() ?? [], ["d/../evil.txt"])
    }
}
