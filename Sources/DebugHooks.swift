import Foundation

/// Otomatik test kancaları (MACRAR_DEBUG_*, MACRAR_SNAPSHOT). Yalnızca `MACRAR_DEBUG_HOOKS=1 ./build.sh` ile yapılan
/// derlemelerde etkindir: yayınlanan sürümde örneğin MACRAR_DEBUG_CONFIRM silme onayını kendiliğinden "Evet" yapmasın.
enum DebugHooks {
    static func env(_ key: String) -> String? {
        #if MACRAR_DEBUG_HOOKS
        return ProcessInfo.processInfo.environment[key]
        #else
        return nil
        #endif
    }
}
