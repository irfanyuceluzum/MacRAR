import Foundation

// Çok küçük bir test çalıştırıcısı: XCTest ve üçüncü parti bağımlılık yok.

enum TestHarness {
    static var total = 0
    static var failedTests = 0
    static var failures = 0
    static var skipped = 0
    static var currentFailed = false
}

/// Bir testi hemen çalıştırır; içindeki başarısız `expect`'ler dosya:satır ile yazılır.
func test(_ name: String, _ body: () -> Void) {
    TestHarness.total += 1
    TestHarness.currentFailed = false
    body()
    if TestHarness.currentFailed {
        TestHarness.failedTests += 1
        print("✘ \(name)")
    } else {
        print("✔ \(name)")
    }
}

/// Üretim kodunda bulunmuş gerçek bir hata için bilinen-hata işareti: test koşmaz, nedeni yazılır.
func knownBug(_ name: String, _ reason: String) {
    TestHarness.skipped += 1
    print("⚠ ATLANDI (bilinen hata) \(name): \(reason)")
}

func recordFailure(_ message: String, file: StaticString, line: UInt) {
    TestHarness.failures += 1
    TestHarness.currentFailed = true
    let short = (String(describing: file) as NSString).lastPathComponent
    print("  \(short):\(line): \(message)")
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "koşul sağlanmadı",
            file: StaticString = #file, line: UInt = #line) {
    if !condition() { recordFailure(message, file: file, line: line) }
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T, _ message: String = "",
                               file: StaticString = #file, line: UInt = #line) {
    let a = actual(), e = expected()
    if a != e {
        recordFailure((message.isEmpty ? "" : message + ": ") + "beklenen \(e), bulunan \(a)", file: file, line: line)
    }
}

/// Sonda özet yazar; hata varsa çıkış kodu 1
func finishTests() -> Never {
    let skip = TestHarness.skipped > 0 ? ", \(TestHarness.skipped) atlandı" : ""
    print("\n\(TestHarness.total) test, \(TestHarness.failures) hata\(skip)")
    exit(TestHarness.failures == 0 ? 0 : 1)
}
