import Foundation

// MARK: - Model

enum ArchiveKind {
    case rar        // okuma 7zz, yazma (isteğe bağlı) kullanıcının RAR aracı
    case other      // 7zz (zip, 7z, tar, gz, xz, bz2, zst, iso, cab, ...)
}

struct ArchiveEntry {
    var name: String            // arşiv içindeki arındırılmış yol (".", ".." ve baştaki "/" atılmış); ağaç ve görüntü bunu kullanır
    var rawName: String = ""    // arşivdeki ham ad; 7zz'ye giden komutlar bunu kullanır (boşsa name)
    var isDirectory: Bool
    var size: Int64 = 0
    var packedSize: Int64 = 0
    var ratio: String = ""
    var mtime: String = ""
    var crc: String = ""
    var encrypted: Bool = false
    var attributes: String = ""
    var compression: String = ""

    /// 7zz'nin çıkartırken yaptığı gibi: boş, "." ve ".." bileşenleri ile baştaki "/" atılır
    static func sanitize(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    /// 7zz'ye verilecek ad
    var commandName: String { rawName.isEmpty ? name : rawName }

    var displayName: String { (name as NSString).lastPathComponent }
    var parentPath: String { (name as NSString).deletingLastPathComponent }
}

struct ArchiveInfo {
    var path: String
    var kind: ArchiveKind
    var details: String
    var entries: [ArchiveEntry]
    var headersEncrypted: Bool = false
    /// tar.gz / tar.xz gibi: dış katman 7zz ile açılıp iç tar'a aktarılır
    var tarCompressed: Bool { Formats.isTarCompressed(path) }

    var hasEncryptedFiles: Bool { headersEncrypted || entries.contains { $0.encrypted } }
    var isSolid: Bool { details.contains("solid") }
    var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    var totalPacked: Int64 { entries.reduce(0) { $0 + $1.packedSize } }
    var topLevelNames: [String] {
        var seen = Set<String>(); var out: [String] = []
        for e in entries {
            guard let top = e.name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init),
                  top != ".", top != ".." else { continue }
            if seen.insert(top).inserted { out.append(top) }
        }
        return out
    }
    /// Dosya ekleme / silme desteklenir mi?
    var supportsModification: Bool {
        if tarCompressed { return false }
        if kind == .rar { return !AppInfo.isAppStore }   // GitHub sürümünde RAR aracı istenir
        return true
    }
}

struct RarResult {
    let code: Int32
    let output: String
    var cancelled: Bool = false

    var ok: Bool { code == 0 || code == 1 }
    var wrongPassword: Bool {
        code == 11 || output.contains("Incorrect password") || output.contains("Wrong password")
            || output.contains("Cannot open encrypted archive")
    }
    var notArchive: Bool { output.contains("is not RAR archive") || output.contains("Cannot open the file as archive") }

    /// Kullanıcıya gösterilecek kısa hata metni
    var errorSummary: String {
        let lines = output.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\u{8}", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("UNRAR ") && !$0.hasPrefix("RAR ") && !$0.hasPrefix("Trial version") && !$0.hasPrefix("Evaluation copy") && !$0.hasPrefix("7-Zip") && !$0.hasPrefix("64-bit") }
        let interesting = lines.filter { l in
            l.contains("error") || l.contains("Error") || l.contains("ERROR") || l.contains("Incorrect") || l.contains("Wrong")
                || l.contains("failed") || l.contains("Failed") || l.contains("not RAR") || l.contains("Cannot") || l.contains("Can not")
                || l.contains("No files") || l.contains("Checksum") || l.contains("CRC") || l.contains("denied") || l.contains("Total errors")
                || l.contains("Unexpected end") || l.contains("Data Error") || l.contains("Unsupported")
        }
        let chosen = interesting.isEmpty ? Array(lines.suffix(6)) : Array(interesting.suffix(8))
        return chosen.joined(separator: "\n")
    }
}

enum RarTool { case rar, sevenZip }

typealias Stage = (tool: RarTool, args: [String])

// MARK: - Biçim bilgisi

enum Formats {
    /// Uygulamanın açabildiği uzantılar
    static let openable: Set<String> = [
        "rar", "zip", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lz4", "lzma", "tlz", "z",
        "cab", "arj", "lzh", "lha", "cpio", "iso", "wim", "swm", "esd", "deb", "rpm", "jar", "war", "ear", "apk", "ipa",
        "xpi", "crx", "nupkg", "msi", "chm", "udf", "vhd", "vhdx", "vmdk", "qcow2", "squashfs", "cramfs", "ext", "ext2", "ext3", "ext4",
        "hfs", "hfsx", "dmg", "xar", "pkg", "ar", "a", "lib", "zipx", "br", "001", "lz", "uue", "bzip2", "gzip", "sfx",
    ]

    static func isArchive(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if openable.contains(ext) { return true }
        return ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil
    }

    static func kind(of path: String) -> ArchiveKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "rar" || ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil { return .rar }
        return .other
    }

    static func filterArchives(_ paths: [String]) -> [String] { paths.filter { isArchive($0) } }

    static func isMultiVolume(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.range(of: #"\.part\d+\.rar$|\.\d{3}$|\.r\d\d$|\.z\d\d$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isTarCompressed(_ path: String) -> Bool {
        let lower = (path as NSString).lastPathComponent.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["tgz", "tbz", "tbz2", "txz", "tzst", "tlz"].contains(ext) { return true }
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4", ".tar.z", ".tar.lzma", ".tar.lz", ".tar.br"] {
            if lower.hasSuffix(suffix) { return true }
        }
        return false
    }
}

// MARK: - Runner

enum RarRunner {
    static let resourceDir: URL = {
        if let r = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: r.appendingPathComponent("7zz").path) {
            return r
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    }()

    static func url(_ tool: RarTool) -> URL {
        switch tool {
        case .rar: return RarTools.rarURL ?? URL(fileURLWithPath: "/nonexistent/rar")
        case .sevenZip: return resourceDir.appendingPathComponent("7zz")
        }
    }

    /// (eski) unrar şifre argümanı: "-p-" = şifre sorma
    static func passwordArg(_ pw: String?, encryptHeaders: Bool = false) -> String {
        guard let pw, !pw.isEmpty else { return "-p-" }
        return (encryptHeaders ? "-hp" : "-p") + pw
    }

    /// rar (a / d) için şifre argümanları. DİKKAT: rar, "-p-" verilince "-" karakterini şifre olarak kullanır;
    /// bu yüzden şifre yoksa hiçbir anahtar verilmez.
    static func rarPasswordArgs(_ pw: String?, encryptHeaders: Bool = false) -> [String] {
        guard let pw, !pw.isEmpty else { return [] }
        return [(encryptHeaders ? "-hp" : "-p") + pw]
    }

    /// 7zz için şifre argümanı ("-p" tek başına: boş şifre, etkileşimli sorma yok)
    static func passwordArg7z(_ pw: String?) -> String {
        guard let pw, !pw.isEmpty else { return "-p" }
        return "-p" + pw
    }

    static func makeProcess(_ tool: RarTool, _ args: [String], cwd: String?) -> Process {
        let p = Process()
        p.executableURL = url(tool)
        // 7zz dosya adlarındaki * ve ? karakterlerini joker sayar: "st*r.txt" silinirken "stXr.txt" de silinir.
        // -spd ile adlar olduğu gibi eşleşir (komuttan hemen sonra; tüm komutlarda geçerli)
        if tool == .sevenZip, let cmd = args.first {
            p.arguments = [cmd, "-spd"] + args.dropFirst()
        } else {
            p.arguments = args
        }
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Eşzamanlı çalıştırır, tüm çıktıyı toplar.
    static func run(_ tool: RarTool, _ args: [String], cwd: String? = nil) -> RarResult {
        runStages([(tool, args)], cwd: cwd)
    }

    /// Boru hattını kurar: her aşamanın çıktısı bir sonrakinin girdisine bağlanır. Son aşamanın stdout/stderr'i
    /// çağırana bırakılır; ara aşamaların stderr'i hata ayrıntısı için toplanır.
    static func makePipeline(_ stages: [Stage], cwd: String?) -> [(process: Process, stderr: StderrSink?)] {
        var out: [(process: Process, stderr: StderrSink?)] = []
        var prevOut: Pipe? = nil
        for (i, st) in stages.enumerated() {
            let p = makeProcess(st.tool, st.args, cwd: cwd)
            // FileHandle değil Pipe verilir: Process başlatınca okuma ucunun bizdeki kopyasını kapatır. Yoksa sonraki aşama
            // erken bitince (tar sonu işareti) önceki aşama SIGPIPE alamaz, boruya yazarken sonsuza dek bekler.
            if let prev = prevOut { p.standardInput = prev }
            var sink: StderrSink? = nil
            if i < stages.count - 1 {
                let o = Pipe()
                p.standardOutput = o
                sink = StderrSink()
                p.standardError = sink!.pipe
                prevOut = o
            }
            out.append((p, sink))
        }
        return out
    }

    /// Tüm aşamaların sonucunu birleştirir: son aşamanın kodu esas alınır, ara aşamalardan biri daha kötü bir kodla
    /// çıktıysa (örn. gzip CRC hatası → 2) o kod döner ve o aşamanın hata çıktısı ayrıntıya eklenir.
    /// Sinyalle (SIGPIPE: okuyan erken bitti, SIGTERM: biz durdurduk) sonlanan ara aşamalar hata sayılmaz.
    static func combinedResult(_ pipeline: [(process: Process, stderr: StderrSink?)], output: String, cancelled: Bool = false) -> RarResult {
        guard let last = pipeline.last?.process else { return RarResult(code: -1, output: output, cancelled: cancelled) }
        var code = last.terminationStatus
        var out = output
        for (p, sink) in pipeline.dropLast() where !p.isRunning && p.terminationReason == .exit && p.terminationStatus != 0 {
            code = max(code, p.terminationStatus)
            if let text = sink?.text, !text.isEmpty { out = text + (text.hasSuffix("\n") ? "" : "\n") + out }
        }
        return RarResult(code: code, output: out, cancelled: cancelled)
    }

    /// Birbirine borulanmış aşamaları eşzamanlı çalıştırır; tüm aşamaların çıkış kodları değerlendirilir.
    /// onLaunch: süreçler başlatılınca çağrılır (başka bir iş parçacığından iptal edebilmek için)
    static func runStages(_ stages: [Stage], cwd: String? = nil, onLaunch: (([Process]) -> Void)? = nil) -> RarResult {
        let pipeline = makePipeline(stages, cwd: cwd)
        guard let last = pipeline.last?.process else { return RarResult(code: -1, output: "") }
        let pipe = Pipe()
        last.standardOutput = pipe
        last.standardError = pipe
        for (p, _) in pipeline {
            do { try p.run() } catch {
                return RarResult(code: -1, output: LF("Çalıştırılamadı: %@", error.localizedDescription))
            }
        }
        onLaunch?(pipeline.map { $0.process })
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipeline.forEach { $0.process.waitUntilExit() }
        pipeline.forEach { $0.stderr?.finish() }
        return combinedResult(pipeline, output: String(decoding: data, as: UTF8.self))
    }

    enum ListOutcome {
        case ok(ArchiveInfo)
        case wrongPassword
        case error(RarResult)
    }

    /// Tüm biçimler (RAR dahil) 7zz ile okunur
    static func listStages(_ path: String, password: String?) -> [Stage] {
        if Formats.isTarCompressed(path) {
            return [(.sevenZip, ["x", "-so", passwordArg7z(password), "--", path]),
                    (.sevenZip, ["l", "-si", "-ttar", "-slt"])]
        }
        return [(.sevenZip, ["l", "-slt", passwordArg7z(password), "--", path])]
    }

    static func list(_ path: String, password: String?) -> ListOutcome {
        listOutcome(runStages(listStages(path, password: password)), path: path)
    }

    /// Listeleme çıktısını yorumlar (ayrıştırma büyük arşivlerde uzun sürer: ana iş parçacığında çağırmayın)
    static func listOutcome(_ r: RarResult, path: String) -> ListOutcome {
        if r.wrongPassword { return .wrongPassword }
        if r.notArchive || (!r.ok && !r.output.contains("----------")) { return .error(r) }
        guard r.output.contains("----------") || r.output.contains("Type = ") else { return .error(r) }
        return .ok(parse7zListing(r.output, path: path, kind: Formats.kind(of: path)))
    }

    // MARK: 7zz l -slt ayrıştırma

    static func parse7zListing(_ out: String, path: String, kind: ArchiveKind = .other) -> ArchiveInfo {
        let lines = out.components(separatedBy: "\n")
        // Son "----------" satırından sonrası girdiler; öncesi arşiv başlık blokları
        let sepIndex = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces) == "----------" }
        let headerLines = sepIndex.map { Array(lines[..<$0]) } ?? lines
        let entryLines = sepIndex.map { Array(lines[($0 + 1)...]) } ?? []

        // Başlık: son "Type =" değeri asıl arşiv türüdür (split/gzip gibi dış katmanlar önce gelir)
        var type = ""
        var solid = false
        var volumes = 0
        var outerTypes: [String] = []
        for raw in headerLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: " = ") else { continue }
            let key = String(line[..<r.lowerBound])
            let value = String(line[r.upperBound...])
            switch key {
            case "Type": if !type.isEmpty { outerTypes.append(type) }; type = value
            case "Solid": solid = (value == "+")
            case "Volumes": volumes = Int(value) ?? 0
            default: break
            }
        }
        if Formats.isTarCompressed(path), type.isEmpty { type = "tar" }

        var entries: [ArchiveEntry] = []
        var block: [String: String] = [:]
        func flush() {
            defer { block = [:] }
            guard let name = block["Path"], !name.isEmpty else { return }
            let attrs = block["Attributes"] ?? ""
            let isDir = block["Folder"] == "+" || attrs.hasPrefix("D")
            let rawName = name.hasSuffix("/") ? String(name.dropLast()) : name
            let clean = ArchiveEntry.sanitize(rawName)
            guard !clean.isEmpty else { return }   // yalnız ".." / "." gibi: diske hiçbir şey yazılmaz
            var e = ArchiveEntry(name: clean, rawName: rawName, isDirectory: isDir)
            e.size = Int64(block["Size"] ?? "") ?? 0
            e.packedSize = Int64(block["Packed Size"] ?? "") ?? 0
            if e.size > 0, e.packedSize > 0 { e.ratio = "\(Int(Double(e.packedSize) * 100 / Double(e.size)))%" }
            if let m = block["Modified"] { e.mtime = String(m.prefix(19)) }
            e.crc = block["CRC"] ?? ""
            e.encrypted = block["Encrypted"] == "+"
            e.attributes = attrs
            e.compression = block["Method"] ?? ""
            entries.append(e)
        }
        for raw in entryLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            guard let r = line.range(of: " = ") else {
                if line.hasSuffix(" =") { block[String(line.dropLast(2))] = "" }
                continue
            }
            let key = String(line[..<r.lowerBound])
            let value = String(line[r.upperBound...])
            if key == "Path", block["Path"] != nil { flush() }
            block[key] = value
        }
        flush()

        let pretty: String
        switch type.lowercased() {
        case "": pretty = L("arşiv")
        case "rar5": pretty = "RAR 5"
        case "rar": pretty = "RAR 4"
        case "7z": pretty = "7z"
        default: pretty = type.uppercased()
        }
        var parts: [String] = [pretty]
        if Formats.isTarCompressed(path) {
            let outerExt = (path as NSString).pathExtension.lowercased()
            parts = ["tar + \(outerExt)"]
        }
        if solid { parts.append("solid") }
        if volumes > 1 { parts.append("\(volumes) volume") }
        var info = ArchiveInfo(path: path, kind: kind, details: parts.joined(separator: ", "), entries: entries)
        info.headersEncrypted = false
        return info
    }
}

// MARK: - Streaming job (ilerleme takibi)

final class RarJob {
    enum Event {
        case file(String)       // yeni dosya işleniyor
        case progress(Int)      // yüzde (toplam)
    }

    private var processes: [Process] = []
    private let lock = NSLock()               // processes ve cancelledFlag için
    private var cancelledFlag = false
    private var monitoredTool: RarTool = .sevenZip
    private let queue = DispatchQueue(label: "macrar.job")
    private var buffer = Data()
    // Çıktı sınırlıdır: ilk ~256 KB ve son ~768 KB tutulur, arası tek satırla özetlenir (yalnız `queue` üzerinde)
    private static let headLimit = 256 * 1024
    private static let tailLimit = 768 * 1024
    private var outHead = ""
    private var outHeadBytes = 0
    private var outTail: [String] = []
    private var outTailStart = 0
    private var outTailBytes = 0
    private var outSkipped = 0
    private var output: String {
        var s = outHead
        if outSkipped > 0 { s += "… (\(outSkipped) satır atlandı) …\n" }
        for i in outTailStart..<outTail.count { s += outTail[i] }
        return s
    }
    private func appendOutput(_ piece: String) {
        if outHeadBytes < Self.headLimit && outSkipped == 0 && outTailStart == outTail.count {
            outHead += piece
            outHeadBytes += piece.utf8.count
            return
        }
        outTail.append(piece)
        outTailBytes += piece.utf8.count
        // Baştan at; en az son satır kalsın
        while outTailBytes > Self.tailLimit && outTailStart < outTail.count - 1 {
            outTailBytes -= outTail[outTailStart].utf8.count
            outTail[outTailStart] = ""
            outTailStart += 1
            outSkipped += 1
        }
        if outTailStart > 4096 && outTailStart * 2 > outTail.count {
            outTail.removeFirst(outTailStart)
            outTailStart = 0
        }
    }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }
    var onEvent: ((Event) -> Void)?   // ana kuyrukta çağrılır

    // Süren işlerin kaydı: çıkışta uyarmak ve süreçleri durdurmak için
    private static var active: [ObjectIdentifier: RarJob] = [:]
    private static let activeLock = NSLock()
    static var hasActive: Bool { activeLock.lock(); defer { activeLock.unlock() }; return !active.isEmpty }
    static func cancelAll() {
        activeLock.lock(); let jobs = Array(active.values); activeLock.unlock()
        jobs.forEach { $0.cancel() }
    }
    private func register() { Self.activeLock.lock(); Self.active[ObjectIdentifier(self)] = self; Self.activeLock.unlock() }
    private func unregister() { Self.activeLock.lock(); Self.active[ObjectIdentifier(self)] = nil; Self.activeLock.unlock() }

    private static let verbs = ["Extracting", "Adding", "Testing", "Updating", "Creating", "Deleting", "Compressing", "Fresh", "Calculating"]
    private static let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})%"#)
    private static let percentHeadRegex = try! NSRegularExpression(pattern: #"^\s*(\d{1,3})%"#)
    private static let tailRegex = try! NSRegularExpression(pattern: #"\s*(\d{1,3}%|OK|Failed|CRC failed)\s*$"#)
    private static let sevenNameRegex = try! NSRegularExpression(pattern: #"(?:^|\s)([-+TU])\s(\S.*)$"#)

    func start(_ tool: RarTool, _ args: [String], cwd: String? = nil, completion: @escaping (RarResult) -> Void) {
        start(stages: [(tool, args)], cwd: cwd, completion: completion)
    }

    /// Aşamalar birbirine borulanır; yalnızca son aşamanın çıktısı izlenir, sonuçta tüm aşamaların çıkış kodu değerlendirilir.
    func start(stages: [Stage], cwd: String? = nil, completion: @escaping (RarResult) -> Void) {
        guard let lastStage = stages.last else { return }
        monitoredTool = lastStage.tool
        let pipeline = RarRunner.makePipeline(stages, cwd: cwd)
        let procs = pipeline.map { $0.process }
        let last = procs[procs.count - 1]
        let pipe = Pipe()
        last.standardOutput = pipe
        last.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            self.queue.async { self.consume(d) }
        }
        last.terminationHandler = { [weak self] proc in
            handle.readabilityHandler = nil
            let rest = handle.readDataToEndOfFile()
            guard let self else { return }
            self.queue.async {
                self.consume(rest)
                self.flushPartial()
                self.lock.lock(); let all = self.processes; self.lock.unlock()
                let others = all.filter { $0 !== proc }
                if self.cancelled || proc.terminationStatus != 0 {
                    // Son aşama hatalı bitti: önceki aşamalar boruya yazarken takılmasın
                    others.forEach { if $0.isRunning { $0.terminate() } }
                } else {
                    // Başarılı bitti: önceki aşamaların kendi çıkış kodunu (örn. gzip CRC hatası) bekle
                    let deadline = Date().addingTimeInterval(5)
                    while others.contains(where: { $0.isRunning }), Date() < deadline { usleep(20_000) }
                    others.forEach { if $0.isRunning { $0.terminate() } }
                }
                others.forEach { $0.waitUntilExit() }
                pipeline.forEach { $0.stderr?.finish() }
                let result = RarRunner.combinedResult(pipeline, output: self.output, cancelled: self.cancelled)
                self.unregister()   // completion'dan önce: bitiş yolunda çıkış uyarısı çıkmasın
                DispatchQueue.main.async { completion(result) }
            }
        }
        lock.lock(); processes = procs; lock.unlock()
        register()
        for p in procs {
            do { try p.run() } catch {
                unregister()
                DispatchQueue.main.async {
                    completion(RarResult(code: -1, output: LF("Çalıştırılamadı: %@", error.localizedDescription)))
                }
                return
            }
        }
    }

    func cancel() {
        lock.lock(); cancelledFlag = true; let procs = processes; lock.unlock()
        procs.forEach { if $0.isRunning { $0.terminate() } }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            appendOutput(Self.lastSegment(line, keepAll: true) + "\n")
            parse(Self.lastSegment(line))
        }
        // Satır sonu gelmeden geri-silme (\u{8}) ile güncellenen ilerleme: yalnızca en son durumu oku
        if !buffer.isEmpty {
            let tail = String(decoding: buffer.suffix(512), as: UTF8.self)
            parse(Self.lastSegment(tail))
            // Uzun süren tek dosyada tampon şişmesin: son geri-silme dizisinden öncesini at
            if buffer.count > 64 * 1024, let cut = buffer.lastIndex(of: 0x08) {
                buffer.removeSubrange(buffer.startIndex...cut)
            }
            // Geri-silme yoksa (ya da hâlâ büyükse) yalnız son kısım tutulur
            if buffer.count > 64 * 1024 {
                buffer = Data(buffer.suffix(4 * 1024))
            }
        }
    }

    /// Geri-silme ile üst üste yazılmış bir satırın ekranda görünen son hali
    private static func lastSegment(_ s: String, keepAll: Bool = false) -> String {
        let parts = s.components(separatedBy: "\u{8}").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if keepAll {
            // Günlük için: tekrar eden yüzde parçalarını at, anlamlı metni koru
            let meaningful = parts.filter { $0.trimmingCharacters(in: .whitespaces).range(of: #"^\d{1,3}%( \d+)?$"#, options: .regularExpression) == nil }
            return meaningful.joined(separator: " ")
        }
        return parts.last ?? ""
    }

    private func flushPartial() {
        if !buffer.isEmpty {
            appendOutput(String(decoding: buffer, as: UTF8.self).replacingOccurrences(of: "\u{8}", with: ""))
            buffer.removeAll()
        }
    }

    private func parse(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\u{8}", with: "").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        var pct: Int? = nil
        var fileName: String? = nil

        if monitoredTool == .sevenZip {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = Self.percentHeadRegex.firstMatch(in: line, range: full) {
                pct = Int(ns.substring(with: m.range(at: 1)))
            }
            if line.contains("ERROR") || line.hasSuffix("--") || line.contains(" Open ") {
                // hata satırları ve "Open --" gibi bilgi satırları dosya değil
            } else if let m = Self.sevenNameRegex.firstMatch(in: line, range: full) {
                var name = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if name.hasSuffix("/") { name.removeLast() }
                if !name.isEmpty, !name.hasPrefix("Everything") { fileName = name }
            }
        } else {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = Self.percentRegex.matches(in: line, range: full).last {
                pct = Int(ns.substring(with: m.range(at: 1)))
            }
            var candidate: String? = nil
            if line.hasPrefix("... ") {
                candidate = String(line.dropFirst(4))        // parça değişiminden sonra devam eden dosya
            } else {
                for verb in Self.verbs where line.hasPrefix(verb + " ") {
                    let rest = String(line.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("from ") || rest.hasPrefix("archive ") { break }
                    candidate = rest
                    break
                }
            }
            if let c = candidate {
                var name = c.trimmingCharacters(in: .whitespaces)
                while let m = Self.tailRegex.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) {
                    name = (name as NSString).substring(to: m.range.location)
                }
                fileName = name.trimmingCharacters(in: .whitespaces)
            }
        }

        guard fileName != nil || pct != nil, let onEvent else { return }
        DispatchQueue.main.async {
            if let f = fileName, !f.isEmpty { onEvent(.file(f)) }
            if let p = pct { onEvent(.progress(p)) }
        }
    }
}

// MARK: - Arka planda listeleme

/// Listelemeyi arka planda çalıştırır; iptal edilebilir. tar.gz / tar.xz gibi arşivlerde bütün akış açıldığından
/// listeleme dakikalar sürebilir: ana iş parçacığı beklemez.
final class ListJob {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelledFlag = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }

    /// Süren listelemeler: uygulama kapanırken 7zz süreçleri arkada (dakikalarca) çalışmaya devam etmesin
    private static var active: [ObjectIdentifier: ListJob] = [:]
    private static let activeLock = NSLock()
    static func cancelAll() {
        activeLock.lock(); let jobs = Array(active.values); activeLock.unlock()
        jobs.forEach { $0.cancel() }
    }

    /// completion ana kuyrukta çağrılır; iptal edildiyse nil
    func start(_ path: String, password: String?, completion: @escaping (RarRunner.ListOutcome?) -> Void) {
        Self.activeLock.lock(); Self.active[ObjectIdentifier(self)] = self; Self.activeLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = RarRunner.runStages(RarRunner.listStages(path, password: password)) { self.adopt($0) }
            // İptal edildiyse yarım çıktıyı boşuna ayrıştırma
            let outcome = self.cancelled ? nil : RarRunner.listOutcome(r, path: path)
            Self.activeLock.lock(); Self.active[ObjectIdentifier(self)] = nil; Self.activeLock.unlock()
            DispatchQueue.main.async { completion(self.cancelled ? nil : outcome) }
        }
    }

    func cancel() {
        lock.lock(); cancelledFlag = true; let procs = processes; lock.unlock()
        procs.forEach { if $0.isRunning { $0.terminate() } }
    }

    /// Süreçler başlatıldı; bu arada iptal istendiyse hemen durdur
    private func adopt(_ procs: [Process]) {
        lock.lock(); processes = procs; let c = cancelledFlag; lock.unlock()
        if c { procs.forEach { if $0.isRunning { $0.terminate() } } }
    }
}

// MARK: - Yardımcılar

/// Boru hattındaki ara bir aşamanın stderr çıktısını arka planda toplar (dolup aşamayı bekletmesin diye)
final class StderrSink {
    let pipe = Pipe()
    private var data = Data()
    private let lock = NSLock()

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.lock.lock(); self.data.append(d); self.lock.unlock()
        }
    }

    /// Süreç bittikten sonra çağrılır: kalan veriyi okur
    func finish() {
        let h = pipe.fileHandleForReading
        h.readabilityHandler = nil
        let rest = h.readDataToEndOfFile()
        lock.lock(); data.append(rest); lock.unlock()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Oturum boyunca oluşturulan geçici klasörler; çıkışta temizlenir
enum TempDirs {
    private static var created: [String] = []
    private static let lock = NSLock()
    static func make(_ prefix: String = "Archiver") -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
        lock.lock(); created.append(p); lock.unlock()
        return p
    }
    static func cleanupAll() {
        lock.lock(); let list = created; created = []; lock.unlock()
        for p in list { try? FileManager.default.removeItem(atPath: p) }
    }
    /// Tek bir geçici klasörü kayıttan düşer ve arka planda siler
    static func remove(_ path: String) {
        lock.lock(); created.removeAll { $0 == path }; lock.unlock()
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(atPath: path) }
    }
    /// Çökme sonrası kalan eski geçici klasörleri siler. 24 saatten yeni olanlara dokunulmaz:
    /// aynı anda çalışan başka MacRAR örnekleri (Finder hızlı eylemleri) kullanıyor olabilir.
    static func sweepStale() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let prefixes = ["Archiver-", "open-", "ql-", "drag-", "rar-install-"]
            let limit = Date().addingTimeInterval(-24 * 3600)
            let root = fm.temporaryDirectory
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
            // Ad tam olarak "<önek>-<UUID>" olmalı (ortak $TMPDIR'de başka uygulamaların klasörlerine dokunma)
            func isOurs(_ name: String) -> Bool {
                for p in prefixes where name.hasPrefix(p) {
                    return UUID(uuidString: String(name.dropFirst(p.count))) != nil
                }
                return false
            }
            for u in items where isOurs(u.lastPathComponent) {
                guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]),
                      v.isSymbolicLink != true,
                      v.isDirectory == true, let m = v.contentModificationDate, m < limit else { continue }
                try? fm.removeItem(at: u)
            }
        }
    }
}

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }
}

func isDirectoryPath(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

func uniquePath(_ path: String) -> String {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return path }
    let ns = path as NSString
    let dir = ns.deletingLastPathComponent
    let ext = ns.pathExtension
    let base = (ns.deletingPathExtension as NSString).lastPathComponent
    var i = 2
    while true {
        let candidate = (dir as NSString).appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
        if !fm.fileExists(atPath: candidate) { return candidate }
        i += 1
    }
}
