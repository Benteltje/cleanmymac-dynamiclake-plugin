import ApplicationServices
import AppKit
import Dispatch
import Foundation

private let schemaVersion = 1
private let pluginName = "CleanMyMac"
private let activityID = "cleanmymac.scan"
private let socketEnvironmentKey = "DYNAMICLAKE_JSON_SOCKET"
private let settingsPathEnvironmentKey = "DYNAMICLAKE_PLUGIN_SETTINGS_PATH"
private let pluginPackageEnvironmentKey = "DYNAMICLAKE_PLUGIN_PACKAGE"
private let pluginPackagePathEnvironmentKey = "DYNAMICLAKE_PLUGIN_PACKAGE_PATH"
private let verboseLoggingEnvironmentKey = "DYNAMICLAKE_CLEANMYMAC_DEBUG"
private let maxFrameSize = 64 * 1024

// MARK: - Time-based Progress Tracking

private var scanStartTime: Date?
private var currentScanPhase: String?
private var executionStartTime: Date?
private var detectedScanType: ScanType?
private var isInExecutionMode = false  // True after user clicks Run
private var lastDetectionTime: Date?
private var currentExecPhase: String?
private var execPhaseIndex = 0  // 0=cleanup, 1=protection, 2=performance, 3=apps, 4=clutter
private var lastPhaseAdvanceTime = Date()
private var phaseStartTime = Date()
private var currentProgressIsExact = false
private var isAwaitingExecution = false
private let cleanupDuration: TimeInterval = 10
private let protectionDuration: TimeInterval = 55
private let totalScanDuration: TimeInterval = 65
private let executionDuration: TimeInterval = 12

// MARK: - Debug Logging

private func debugLogPath() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = appSupport.appendingPathComponent("DynamicLake", isDirectory: true)
        .appendingPathComponent("PluginLogs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("cleanmymac-debug.log")
}

private func debugLog(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(message)\n"
    let url = debugLogPath()
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

private let verboseLoggingEnabled: Bool = {
    guard let value = ProcessInfo.processInfo.environment[verboseLoggingEnvironmentKey] else { return false }
    return ["1", "true", "yes", "on"].contains(value.lowercased())
}()

private func verboseLog(_ message: @autoclosure () -> String) {
    guard verboseLoggingEnabled else { return }
    debugLog(message())
}

// MARK: - Scan Types & Colors

private enum ScanType: String {
    case smartScan = "Smart Care"
    case systemJunk = "Cleanup"
    case mailAttachment = "Mail Attachments"
    case trash = "Trash Bins"
    case malware = "Protection"
    case privacy = "Privacy"
    case optimize = "Performance"
    case myClutter = "My Clutter"
    case spaceLens = "Space Lens"
    case cloudCleanup = "Cloud Cleanup"
    case uninstaller = "Applications"
    case extensions = "Extensions"
    case unknown = "Scanning"

    var color: String {
        switch self {
        // DynamicLake supports named palette colors only. Its purple token is
        // the closest match to the official Smart Care artwork (#FF7BDB);
        // the pink token renders noticeably redder.
        case .smartScan: return "purple"
        case .systemJunk: return "green"
        case .mailAttachment: return "orange"
        case .trash: return "red"
        case .malware: return "pink"
        case .privacy: return "indigo"
        case .optimize: return "orange"
        case .myClutter: return "cyan"
        case .spaceLens: return "purple"
        case .cloudCleanup: return "blue"
        case .uninstaller: return "blue"
        case .extensions: return "cyan"
        case .unknown: return "white"
        }
    }

    var icon: String {
        switch self {
        case .smartScan: return "sparkles"
        case .systemJunk: return "trash"
        case .mailAttachment: return "envelope"
        case .trash: return "trash.fill"
        case .malware: return "shield.lefthalf.filled"
        case .privacy: return "lock.shield"
        case .optimize: return "gauge.medium"
        case .myClutter: return "folder"
        case .spaceLens: return "externaldrive"
        case .cloudCleanup: return "cloud"
        case .uninstaller: return "xmark.app"
        case .extensions: return "puzzlepiece.extension"
        case .unknown: return "antenna.radiowaves.left.and.right"
        }
    }

    /// Official CleanMyMac artwork extracted from the matching module bundle.
    /// Smart Care uses the official app icon already shipped with the plugin.
    var assetFile: String {
        switch self {
        case .smartScan: return "Assets/CleanMyMac-Smart-Care.png"
        case .unknown: return "CleanMyMacIcon.png"
        case .systemJunk, .mailAttachment, .trash: return "Assets/CleanMyMac-Cleanup.png"
        case .malware, .privacy: return "Assets/CleanMyMac-Protection.png"
        case .optimize: return "Assets/CleanMyMac-Performance.png"
        case .uninstaller, .extensions: return "Assets/CleanMyMac-Applications.png"
        case .myClutter: return "Assets/CleanMyMac-My-Clutter.png"
        case .spaceLens: return "Assets/CleanMyMac-Space-Lens.png"
        case .cloudCleanup: return "Assets/CleanMyMac-Cloud-Cleanup.png"
        }
    }

    static func detect(from text: String) -> ScanType {
        let lower = text.lowercased()
        
        // Check for scanning action keywords FIRST - these indicate an active scan
        let isActivelyScanning = lower.contains("looking for") || lower.contains("searching for")
            || lower.contains("scanning for") || lower.contains("zoeken naar")
            || lower.contains("aan het zoeken") || lower.contains("recherche de")
            || lower.contains("nach") && lower.contains("suchen")
            || lower.contains("alla ricerca di") || lower.contains("検索")
            || lower.contains("검색") || lower.contains("szukanie")
            || lower.contains("procurando por") || lower.contains("buscando")
            || lower.contains("пошук") || lower.contains("正在搜索")
            || lower.contains("examining") || lower.contains("analyzing")
            || lower.contains("controllo") || lower.contains("überprüft")
            || lower.contains("analyse") || lower.contains("검사")
            || lower.contains("analiza") || lower.contains("analisando")
            || lower.contains("analizando") || lower.contains("аналіз")
            || lower.contains("uw opslag") || lower.contains("正在分析")
            || lower.contains("cleaning") || lower.contains("removing")
            || lower.contains("aan het opruimen") || lower.contains("aan het verwijderen")
            || lower.contains("nettoyage en cours") || lower.contains("suppression en cours")
            || lower.contains("wird bereinigt") || lower.contains("wird entfernt")
            || lower.contains("pulizia in corso") || lower.contains("rimozione in corso")
            || lower.contains("クリーン中") || lower.contains("削除中")
            || lower.contains("정리 중") || lower.contains("제거 중")
            || lower.contains("czyszczenie") || lower.contains("usuwanie")
            || lower.contains("limpando") || lower.contains("removendo")
            || lower.contains("limpiando") || lower.contains("eliminando")
            || lower.contains("очищення") || lower.contains("видалення")
        
        // If not actively scanning, check for idle state (results page)
        let isIdle = lower.contains("well done") || lower.contains("goed gedaan")
            || lower.contains("start over") || lower.contains("begin opnieuw")
            || lower.contains("bien joué") || lower.contains("gut gemacht")
            || lower.contains("ben fatto") || lower.contains("результат")
        
        // If idle, don't detect a scan type
        if isIdle && !isActivelyScanning { return .unknown }
        
        // Now detect specific scan type based on content
        
        // Check Smart Scan phases FIRST - these are specific phrases used ONLY during Smart Scan
        // Smart Scan uses "looking for junk", "looking for threats", "examining your system", etc.
        let isSmartScanPhase = lower.contains("looking for junk") || lower.contains("naar rommel zoeken")
            || lower.contains("searching for junk") || lower.contains("scanning for junk")
            || lower.contains("looking for threats") || lower.contains("zoeken naar bedreigingen")
            || lower.contains("searching for threats") || lower.contains("scanning for threats")
            || lower.contains("examining your system") || lower.contains("uw systeem scannen")
            || lower.contains("votre système") || lower.contains("überprüft ihr system")
            || lower.contains("looking for updates") || lower.contains("checking for updates")
            || lower.contains("recherche de mises à jour") || lower.contains("vérification des mises à jour")
            || lower.contains("nach updates suchen") || lower.contains("nach updates prüfen")
            || lower.contains("alla ricerca di aggiornamenti") || lower.contains("controllo aggiornamenti")
            || lower.contains("analyzing your storage") || lower.contains("analyse de votre stockage")
            || lower.contains("überprüft ihren speicher") || lower.contains("analisi del tuo archivio")
            || lower.contains("正在搜索垃圾") || lower.contains("正在搜索威胁")
            || lower.contains("正在检查系统") || lower.contains("正在搜索更新")
            || lower.contains("正在分析存储")
        
        // Also detect Smart Scan via ModuleNameLabel value "Smart Care" or "Smart Scan"
        // NOTE: Don't check for "Smart Care" in combined text - it's always in the sidebar!
        // Only check for specific Smart Scan keywords that appear during scanning
        let isSmartScanModule = lower == "smart care" || lower == "smart scan"
            || lower == "slimme scan" || lower == "intelligenter scan"
            || lower == "scan intelligente" || lower == "интеллектуальное"
            || lower == "스마트 스캔" || lower == "inteligentny"
            || lower == "inteligente limpeza"
        
        if isSmartScanPhase || isSmartScanModule { return .smartScan }
        
        // Now check specific scan types (for individual scans)
        
        // Check for IntroViewTitleLabel which shows the module name during individual scans
        // This is more reliable than checking scanning text
        
        // System Junk (all languages) - exact match for module name
        if lower == "system junk" || lower == "systeem rommel" || lower == "déchets système"
            || lower == "systemmüll" || lower == "sporco di sistema" || lower == "システムジャンク"
            || lower == "시스템 쓰레기" || lower == "śmieci systemowe" || lower == "lixo do sistema"
            || lower == "basura del sistema" || lower == "сміття системи" { return .systemJunk }
        
        // Cleanup (general) - exact match for module name
        if lower == "cleanup" || lower == "opruimen" || lower == "nettoyage"
            || lower == "bereinigung" || lower == "pulizia" || lower == "クリーンアップ"
            || lower == "czyszczenie" || lower == "limpeza"
            || lower == "limpieza" || lower == "очищення" { return .systemJunk }
        
        // Mail Attachments - exact match for module name
        if lower == "mail attachments" || lower == "mailbijlagen" || lower == "pièces jointes mail"
            || lower == "mailanhang" || lower == "allegati email" || lower == "メール添付"
            || lower == "메일 첨부" || lower == "załączniki pocztowe" || lower == "anexos de email"
            || lower == "поштові додатки" { return .mailAttachment }
        
        // Trash Bins
        if lower == "trash bins" || lower == "prullenbakken" || lower == "corbeilles"
            || lower == "papierkörbe" || lower == "cestini" || lower == "ごみ箱"
            || lower == "휴지통" || lower == "kosze" || lower == "lixeiras"
            || lower == "papelera" || lower == "смітники" { return .trash }
        
        // Malware Removal (mapped from "Protection" module name)
        if lower == "protection" || lower == "bescherming" || lower == "protection"
            || lower == "schutz" || lower == "protezione" || lower == "保護"
            || lower == "보호" || lower == "ochrona" || lower == "proteção"
            || lower == "protección" || lower == "захист" { return .malware }
        
        // Malware Removal (explicit)
        if lower == "malware removal" || lower == "malware verwijdering" || lower == "suppression de logiciels malveillants"
            || lower == "malware entfernung" || lower == "rimozione malware" || lower == "マルウェア除去"
            || lower == "멀웨어 제거" || lower == "usuwanie złośliwego oprogramowania" || lower == "remoção de malware"
            || lower == "eliminación de malware" || lower == "видалення шкідливого ПЗ" { return .malware }
        
        // Privacy
        if lower == "privacy" || lower == "privacy" || lower == "vie privée"
            || lower == "datenschutz" || lower == "privacy" || lower == "プライバシー"
            || lower == "개인정보" || lower == "prywatność" || lower == "privacidade"
            || lower == "privacidad" || lower == "конфіденційність" { return .privacy }
        
        // Optimize / Performance (mapped from "Performance" module name)
        if lower == "performance" || lower == "prestaties" || lower == "performances"
            || lower == "leistung" || lower == "prestazioni" || lower == "パフォーマンス"
            || lower == "성능" || lower == "wydajność" || lower == "desempenho"
            || lower == "rendimiento" || lower == "продуктивність" { return .optimize }
        
        // Space Lens
        if lower == "space lens" || lower == "ruimtelens" || lower == "lentille d'espace"
            || lower == "speicherlinse" || lower == "lente spaziale" || lower == "スペースレンズ"
            || lower == "공간 렌즈" || lower == "soczewka przestrzenna" || lower == "lente espacial"
            || lower == "lente de espacio" || lower == "просторова лінза" { return .spaceLens }

        // Cloud Cleanup
        if lower == "cloud cleanup" || lower == "cloudopruiming" || lower == "nettoyage du cloud"
            || lower == "cloud-bereinigung" || lower == "pulizia cloud" || lower == "クラウドクリーンアップ"
            || lower == "클라우드 정리" || lower == "czyszczenie chmury" || lower == "limpeza da nuvem"
            || lower == "limpieza de la nube" || lower == "очищення хмари" { return .cloudCleanup }
        
        // Uninstaller / Applications (mapped from "Applications" module name)
        if lower == "applications" || lower == "toepassingen" || lower == "applications"
            || lower == "anwendungen" || lower == "applicazioni" || lower == "アプリケーション"
            || lower == "앱lications" || lower == "aplikacje" || lower == "aplicativos"
            || lower == "aplicaciones" || lower == "програми" { return .uninstaller }
        
        // Uninstaller (explicit)
        if lower == "uninstaller" || lower == "verwijderaar" || lower == "désinstallateur"
            || lower == "deinstaller" || lower == "disinstallatore" || lower == "アンインストーラー"
            || lower == "제거기" || lower == "odinstalator" || lower == "desinstalador"
            || lower == "desinstalador" || lower == "видалення" { return .uninstaller }
        
        // Extensions
        if lower == "extensions" || lower == "extensies" || lower == "extensions"
            || lower == "erweiterungen" || lower == "estensioni" || lower == "拡張機能"
            || lower == "확장" || lower == "rozbudowy" || lower == "extensões"
            || lower == "extensiones" || lower == "розширення" { return .extensions }
        
        // My Clutter
        if lower == "my clutter" || lower == "mijn rommel" || lower == "mes déchets"
            || lower == "mein unordnung" || lower == "i miei disordini" || lower == "マイクラッター"
            || lower == "내 클러터" || lower == "mój bałagan" || lower == "meus entulhos"
            || lower == "mi desorden" || lower == "мій безлад" { return .myClutter }
        
        // Trash Bins
        if lower.contains("trash") || lower.contains("prullenbak") || lower.contains("corbeille")
            || lower.contains("papierkorb") || lower.contains("cestino") || lower.contains("ごみ箱")
            || lower.contains("휴지통") || lower.contains("kosz") || lower.contains("lixeira")
            || lower.contains("papelera") || lower.contains("смітник") { return .trash }
        
        // Malware / Protection (all languages)
        if lower.contains("malware") || lower.contains("virus") || lower.contains("bedreigingen")
            || lower.contains("bescherming") || lower.contains("menaces") || lower.contains("bedrohungen")
            || lower.contains("minacce") || lower.contains("脅威") || lower.contains("위협")
            || lower.contains("zagrożenia") || lower.contains("ameaças") || lower.contains("amenazas")
            || lower.contains("загрози") || lower.contains("threats") { return .malware }
        
        // Privacy
        if lower.contains("privacy") || lower.contains("privacidad") || lower.contains("confidentialité")
            || lower.contains("datenschutz") || lower.contains("隐私") || lower.contains("prywatność")
            || lower.contains("privacidade") || lower.contains("приватність") { return .privacy }
        
        // Optimize / Performance (all languages)
        if lower.contains("optimiz") || lower.contains("maintenance") || lower.contains("prestaties")
            || lower.contains("performance") || lower.contains("leistung") || lower.contains("prestazioni")
            || lower.contains("パフォーマンス") || lower.contains("성능") || lower.contains("wydajność")
            || lower.contains("desempenho") || lower.contains("rendimiento") || lower.contains("продуктивність") { return .optimize }
        
        // Space Lens
        if lower.contains("space lens") || lower.contains("ruimtelens") || lower.contains("espace")
            || lower.contains("speicher") || lower.contains("spazio") || lower.contains("スペース")
            || lower.contains("공간") || lower.contains("przestrzeń") || lower.contains("espaço")
            || lower.contains("espacio") || lower.contains("простір") { return .spaceLens }

        // Cloud Cleanup
        if lower.contains("cloud cleanup") || lower.contains("cloudopruiming")
            || lower.contains("nettoyage du cloud") || lower.contains("cloud-bereinigung")
            || lower.contains("pulizia cloud") || lower.contains("クラウドクリーンアップ")
            || lower.contains("클라우드 정리") || lower.contains("czyszczenie chmury")
            || lower.contains("limpeza da nuvem") || lower.contains("limpieza de la nube")
            || lower.contains("очищення хмари") { return .cloudCleanup }

        // My Clutter (keep separate from Space Lens)
        if lower.contains("my clutter") || lower.contains("mijn rommel") || lower.contains("mes déchets")
            || lower.contains("mein unordnung") || lower.contains("i miei disordini")
            || lower.contains("マイクラッター") || lower.contains("내 클러터")
            || lower.contains("mój bałagan") || lower.contains("meus entulhos")
            || lower.contains("mi desorden") || lower.contains("мій безлад") { return .myClutter }
        
        // Uninstaller / Applications (all languages)
        if lower.contains("uninstall") || lower.contains("app uninstaller") || lower.contains("toepassingen")
            || lower.contains("désinstallation") || lower.contains("deinstallation") || lower.contains("disinstallazione")
            || lower.contains("アンインストール") || lower.contains("제거") || lower.contains("odinstalowanie")
            || lower.contains("desinstalação") || lower.contains("desinstalación") || lower.contains("видалення") { return .uninstaller }
        
        // Extensions
        if lower.contains("extension") || lower.contains("erweiterung") || lower.contains("estensione")
            || lower.contains("拡張") || lower.contains("확장") || lower.contains("rozbudowa")
            || lower.contains("extensão") || lower.contains("extensión") || lower.contains("розширення") { return .extensions }
        
        // Smart Scan - only if actively scanning and no specific type matched
        if isActivelyScanning { return .smartScan }
        
        return .unknown
    }
}

// MARK: - Settings

private struct PluginSettings: Equatable {
    var pollSeconds: TimeInterval = 0.5
    var showOnIdle = false
    var compactPresentation: CompactPresentation = .moduleIcon
}

private enum CompactPresentation: String {
    case moduleIcon = "Module icon"
    case moduleName = "Module name"
}

// MARK: - Errors

private enum PluginError: Error, CustomStringConvertible {
    case socketPathMissing
    case socket(String)
    case frameTooLarge(Int)

    var description: String {
        switch self {
        case .socketPathMissing: return "\(socketEnvironmentKey) is missing"
        case .socket(let msg): return msg
        case .frameTooLarge(let s): return "JSON frame too large: \(s) bytes"
        }
    }
}

// MARK: - JSON Socket Client

private final class JSONSocketClient {
    let socketPath: String
    private var fd: Int32 = -1
    private var readBuffer = Data()

    init(socketPath: String) { self.socketPath = socketPath }
    deinit { close() }

    func connect() throws {
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PluginError.socket("socket failed: \(String(cString: strerror(errno)))") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else { throw PluginError.socket("path too long") }

        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    memset(dst, 0, maxLen)
                    strncpy(dst, src, maxLen - 1)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw PluginError.socket("connect: \(String(cString: strerror(errno)))") }

        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    func send(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard data.count <= maxFrameSize else { throw PluginError.frameTooLarge(data.count) }
        var frame = Data()
        var len = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(data)
        try sendAll(frame)
    }

    func receiveAvailable() -> [[String: Any]] {
        guard fd >= 0 else { return [] }

        var buf = [UInt8](repeating: 0, count: 4096)
        let capacity = buf.count
        while true {
            let count = buf.withUnsafeMutableBytes { ptr in
                Darwin.recv(fd, ptr.baseAddress, capacity, 0)
            }
            if count > 0 {
                readBuffer.append(buf, count: count)
                continue
            }
            if count == 0 { break }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            break
        }

        var messages: [[String: Any]] = []
        while readBuffer.count >= 4 {
            let lenData = readBuffer.prefix(4)
            let length = lenData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if length > maxFrameSize { readBuffer.removeAll(); break }
            let total = Int(length) + 4
            guard readBuffer.count >= total else { break }
            let body = readBuffer.subdata(in: 4..<total)
            readBuffer.removeSubrange(0..<total)
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                messages.append(obj)
            }
        }
        return messages
    }

    private func sendAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let r = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if r > 0 { sent += r; continue }
                if r < 0 && errno == EINTR { continue }
                if r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(10_000); continue }
                throw PluginError.socket("send: \(String(cString: strerror(errno)))")
            }
        }
    }
}

// MARK: - Settings Loader

private func environmentSettingKey(for id: String) -> String {
    var key = ""
    for scalar in id.unicodeScalars {
        if CharacterSet.uppercaseLetters.contains(scalar), !key.isEmpty, !key.hasSuffix("_") { key.append("_") }
        if CharacterSet.alphanumerics.contains(scalar) { key.append(String(scalar).uppercased()) }
        else if !key.hasSuffix("_") { key.append("_") }
    }
    return "DYNAMICLAKE_SETTING_\(key.trimmingCharacters(in: CharacterSet(charactersIn: "_")))"
}

private func loadSettings() -> PluginSettings {
    var values: [String: Any] = [:]
    if let path = ProcessInfo.processInfo.environment[settingsPathEnvironmentKey],
       let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        values = (obj["values"] as? [String: Any]) ?? obj
    }
    func get(_ id: String, _ def: Any) -> Any {
        values[id] ?? ProcessInfo.processInfo.environment[environmentSettingKey(for: id)] ?? def
    }
    func double(_ id: String, default def: Double) -> Double {
        let value = get(id, def)
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let number = Double(string) { return number }
        return def
    }
    func bool(_ id: String, default def: Bool) -> Bool {
        let value = get(id, def)
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes", "on"].contains(string.lowercased())
        }
        return def
    }
    func string(_ id: String, default def: String) -> String {
        get(id, def) as? String ?? def
    }

    let poll = double("pollSeconds", default: 0.5)
    let idle = bool("showOnIdle", default: false)
    let presentation = CompactPresentation(
        rawValue: string("compactPresentation", default: CompactPresentation.moduleIcon.rawValue)
    ) ?? .moduleIcon
    return PluginSettings(
        pollSeconds: min(max(poll, 0.5), 5),
        showOnIdle: idle,
        compactPresentation: presentation
    )
}

// MARK: - Accessibility: CleanMyMac Detection

private let cmmMainBundleIDs = [
    "com.macpaw.CleanMyMac5",
    "com.macpaw.CleanMyMacX",
    "com.macpaw.CleanMyMac"
]

private let cmmBundleIDs = cmmMainBundleIDs + [
    "com.macpaw.CleanMyMac5.Menu",
    "com.macpaw.CleanMyMacX.Menu",
    "com.macpaw.CleanMyMac.Menu"
]

private let cmmProcessNames = [
    "CleanMyMac_5", "CleanMyMac X", "CleanMyMac", "CleanMyMac Menu"
]

/// Collects all text content from an AX element and its children.
private func allText(from element: AXUIElement, depth: Int = 0) -> [String] {
    guard depth < 10 else { return [] }
    var texts: [String] = []

    func readAttr(_ element: AXUIElement, _ key: CFString) -> String? {
        var val: AnyObject?
        AXUIElementCopyAttributeValue(element, key, &val)
        return val as? String
    }

    if let s = readAttr(element, kAXTitleAttribute as CFString), !s.isEmpty { texts.append(s) }
    if let s = readAttr(element, kAXDescriptionAttribute as CFString), !s.isEmpty { texts.append(s) }
    if let s = readAttr(element, kAXValueAttribute as CFString), !s.isEmpty { texts.append(s) }
    if let s = readAttr(element, "AXLabel" as CFString), !s.isEmpty { texts.append(s) }

    var children: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    if let arr = children as? [AXUIElement] {
        for child in arr { texts.append(contentsOf: allText(from: child, depth: depth + 1)) }
    }
    return texts
}

/// Extracts the ModuleNameLabel value from the AX tree (e.g., "Smart Care", "Cleanup", "Malware Removal")
private func extractModuleName(from element: AXUIElement, depth: Int = 0) -> String? {
    guard depth < 15 else { return nil }

    var ident: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &ident)
    if let id = ident as? String, id == "ModuleNameLabel" {
        var val: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &val)
        if let value = val as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    
    var children: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    if let arr = children as? [AXUIElement] {
        for child in arr {
            if let name = extractModuleName(from: child, depth: depth + 1) {
                return name
            }
        }
    }
    return nil
}

/// Extracts the IntroViewTitleLabel value from the AX tree (shows module name before scan starts)
private func extractIntroTitle(from element: AXUIElement, depth: Int = 0) -> String? {
    guard depth < 15 else { return nil }
    
    var ident: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &ident)
    if let id = ident as? String, id == "IntroViewTitleLabel" {
        var val: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &val)
        if let value = val as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    
    var children: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    if let arr = children as? [AXUIElement] {
        for child in arr {
            if let name = extractIntroTitle(from: child, depth: depth + 1) {
                return name
            }
        }
    }
    return nil
}

/// True only for status labels that describe work happening right now. Using
/// the complete window text caused result buttons such as "Remove" and stale
/// sidebar content to be mistaken for a newly started action.
private func hasActiveOperation(in texts: [String]) -> Bool {
    let activePhrases = [
        "cleaning ", "removing ", "checking ", "scanning ", "analyzing ",
        "processing ", "digging through", "visualizing your storage space",
        "running your task", "installing update",
        "decluttering", "aan het opruimen", "aan het verwijderen",
        "aan het controleren", "aan het analyseren", "aan het scannen",
        "nettoyage en cours", "suppression en cours", "vérification en cours",
        "wird bereinigt", "wird entfernt", "wird überprüft", "wird gescannt",
        "pulizia in corso", "rimozione in corso", "controllo in corso",
        "クリーン中", "削除中", "確認中", "スキャン中", "分析中", "処理中",
        "정리 중", "제거 중", "확인 중", "스캔 중", "분석 중", "처리 중"
    ]
    return texts.contains { text in
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return activePhrases.contains { normalized.contains($0) }
    }
}

private func isMyClutterResultsPage(_ texts: [String], moduleName: String?) -> Bool {
    guard moduleName.map(ScanType.detect(from:)) == .myClutter else { return false }
    let combined = texts.joined(separator: " ").lowercased()
    let hasResultContent = combined.contains("files to sort through")
        || combined.contains("review all files")
    return combined.contains("start over") && hasResultContent
}

private func isSpaceLensResultsPage(_ texts: [String], moduleName: String?) -> Bool {
    guard moduleName.map(ScanType.detect(from:)) == .spaceLens else { return false }
    let combined = texts.joined(separator: " ").lowercased()
    guard combined.contains("start over") else { return false }
    let hasEmptyResult = combined.contains("too empty to visualize")
    let hasStorageMap = combined.contains("macintosh hd")
        && combined.contains(" used")
    return hasEmptyResult || hasStorageMap
}

private func estimatedStorageProgress(scanType: ScanType, elapsed: TimeInterval) -> Int {
    let expectedDuration: TimeInterval
    switch scanType {
    case .myClutter: expectedDuration = 85
    case .spaceLens: expectedDuration = 120
    case .cloudCleanup: expectedDuration = 90
    default: expectedDuration = 75
    }
    return min(95, max(1, Int((elapsed / expectedDuration) * 95)))
}

private func resetTrackedActivity() {
    scanStartTime = nil
    currentScanPhase = nil
    executionStartTime = nil
    detectedScanType = nil
    lastDetectionTime = nil
    currentExecPhase = nil
    isInExecutionMode = false
    isAwaitingExecution = false
    execPhaseIndex = 0
}

/// Searches the entire AX hierarchy for a percentage value (0-100).
private func findPercentage(in element: AXUIElement, depth: Int = 0) -> Int? {
    guard depth < 15 else { return nil }

    // Check if this is a progress indicator
    var role: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    if let roleStr = role as? String, roleStr == "AXProgressIndicator" {
        var val: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &val)
        if let num = val as? NSNumber {
            let d = num.doubleValue
            if d >= 0 && d <= 1.0 {
                let pct = Int(d * 100)
                verboseLog("AXProgressIndicator value=\(d) -> \(pct)%")
                return pct
            }
            if d >= 0 && d <= 100 {
                verboseLog("AXProgressIndicator value=\(d) -> \(Int(d))%")
                return Int(d)
            }
        }
    }

    // Check all text attributes for percentage patterns
    func readAttr2(_ element: AXUIElement, _ key: CFString) -> String? {
        var val: AnyObject?
        AXUIElementCopyAttributeValue(element, key, &val)
        return val as? String
    }

    if let s = readAttr2(element, kAXTitleAttribute as CFString) {
        if let pct = extractPercentage(from: s) { return pct }
    }
    if let s = readAttr2(element, kAXDescriptionAttribute as CFString) {
        if let pct = extractPercentage(from: s) { return pct }
    }
    if let s = readAttr2(element, kAXValueAttribute as CFString) {
        if let pct = extractPercentage(from: s) { return pct }
    }
    if let s = readAttr2(element, "AXLabel" as CFString) {
        if let pct = extractPercentage(from: s) { return pct }
    }

    // Recurse
    var children: AnyObject?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    if let arr = children as? [AXUIElement] {
        for child in arr {
            if let pct = findPercentage(in: child, depth: depth + 1) { return pct }
        }
    }
    return nil
}

private func extractPercentage(from text: String) -> Int? {
    let pattern = "(\\d{1,3})\\s*%"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    let num = Int(text[range]) ?? 0
    return (num >= 0 && num <= 100) ? num : nil
}

private struct AXWindowSnapshot {
    var texts: [String] = []
    var moduleName: String?
    var introTitle: String?
    var progress: Int?
}

/// Reads each AX node once. Earlier versions walked the same tree separately
/// for text, module name, intro title, and progress, multiplying IPC work.
private func collectAXWindowSnapshot(from root: AXUIElement) -> AXWindowSnapshot {
    var snapshot = AXWindowSnapshot()

    func attribute(_ element: AXUIElement, _ key: CFString) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, key, &value)
        return value
    }

    func visit(_ element: AXUIElement, depth: Int) {
        guard depth < 15 else { return }

        let title = attribute(element, kAXTitleAttribute as CFString) as? String
        let description = attribute(element, kAXDescriptionAttribute as CFString) as? String
        let rawValue = attribute(element, kAXValueAttribute as CFString)
        let value = rawValue as? String
        let label = attribute(element, "AXLabel" as CFString) as? String

        if depth < 10 {
            for text in [title, description, value, label].compactMap({ $0 }) where !text.isEmpty {
                snapshot.texts.append(text)
            }
        }

        let identifier = attribute(element, kAXIdentifierAttribute as CFString) as? String
        if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            if identifier == "ModuleNameLabel", snapshot.moduleName == nil { snapshot.moduleName = trimmed }
            if identifier == "IntroViewTitleLabel", snapshot.introTitle == nil { snapshot.introTitle = trimmed }
        }

        if snapshot.progress == nil {
            let role = attribute(element, kAXRoleAttribute as CFString) as? String
            if role == "AXProgressIndicator", let number = rawValue as? NSNumber {
                let numericValue = number.doubleValue
                if numericValue >= 0, numericValue <= 1 {
                    snapshot.progress = Int(numericValue * 100)
                } else if numericValue >= 0, numericValue <= 100 {
                    snapshot.progress = Int(numericValue)
                }
            }
            if snapshot.progress == nil {
                snapshot.progress = [title, description, value, label]
                    .compactMap { $0 }
                    .compactMap(extractPercentage(from:))
                    .first
            }
        }

        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children { visit(child, depth: depth + 1) }
        }
    }

    visit(root, depth: 0)
    return snapshot
}

/// Bundle names of the CleanMyMac main app (NOT helpers like Menu/HealthMonitor).
private let cmmMainBundleNames = ["CleanMyMac_5", "CleanMyMac X", "CleanMyMac"]

/// True for the main app executable, e.g.
/// /Applications/CleanMyMac_5.app/Contents/MacOS/CleanMyMac_5
/// Excludes helpers: FinderSyncExtension.appex, LoginItems (Menu/HealthMonitor),
/// PrivilegedHelperTools (Agent) — all live outside <Name>.app/Contents/MacOS/.
private func isMainCMMExecutable(_ exePath: String) -> Bool {
    guard let range = exePath.range(of: ".app/Contents/MacOS/") else { return false }
    let bundlePath = String(exePath[..<range.lowerBound])
    let bundleName = (bundlePath as NSString).lastPathComponent
    return cmmMainBundleNames.contains(bundleName)
}

private var cachedCMMMainPID: pid_t = 0
private var lastCMMProcessScan = Date.distantPast
private let cmmProcessScanCooldown: TimeInterval = 10

private func invalidateCMMMainPIDCache() {
    cachedCMMMainPID = 0
    lastCMMProcessScan = .distantPast
}

/// Finds the CleanMyMac main app PID via a kernel query (libproc).
/// NSWorkspace.shared.runningApplications turned out to be a stale snapshot
/// inside this long-running plugin process (dead PIDs linger, fresh ones
/// missing), so libproc remains the source of truth. Positive results are
/// retained while the process lives and negative scans are throttled.
private func findCMMMainPID(forceRefresh: Bool = false) -> pid_t {
    if cachedCMMMainPID > 0 {
        if kill(cachedCMMMainPID, 0) == 0 { return cachedCMMMainPID }
        cachedCMMMainPID = 0
    }

    if !forceRefresh, Date().timeIntervalSince(lastCMMProcessScan) < cmmProcessScanCooldown {
        return 0
    }
    lastCMMProcessScan = Date()

    let size = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0))
    guard size > 0 else { return 0 }
    var pids = [pid_t](repeating: 0, count: size / MemoryLayout<pid_t>.size + 1)
    let bytes = pids.withUnsafeMutableBytes { ptr in
        proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress, Int32(ptr.count))
    }
    guard bytes > 0 else { return 0 }
    let count = Int(bytes) / MemoryLayout<pid_t>.size
    for i in 0..<min(count, pids.count) {
        let pid = pids[i]
        guard pid > 1 else { continue }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = path.withUnsafeMutableBytes { ptr in
            proc_pidpath(pid, ptr.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(ptr.count))
        }
        guard len > 0 else { continue }
        if isMainCMMExecutable(String(cString: path)) {
            cachedCMMMainPID = pid
            return pid
        }
    }
    return 0
}

/// Fallback detection via CGWindowList (no Accessibility permissions needed)
private func detectViaCGWindow(pid: pid_t) -> (isScanning: Bool, scanType: ScanType, progress: Int)? {
    guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    var allTexts: [String] = []
    for info in windowList {
        guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { continue }
        if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
            allTexts.append(name)
        }
        if let layer = info[kCGWindowLayer as String] as? Int, layer == 0 {
            // Normal window
        }
    }

    guard !allTexts.isEmpty else { return nil }

    let combined = allTexts.joined(separator: " ").lowercased()
    verboseLog("CGWindow texts: \(allTexts.prefix(5))")

    let isScanning = combined.contains("scanning") || combined.contains("analyzing")
        || combined.contains("looking for") || combined.contains("cleaning")
        || combined.contains("removing") || combined.contains("optimizing")
        || combined.contains("zoeken") || combined.contains("opruimen")
        || combined.contains("verwijderen") || combined.contains("optimaliseren")
        || combined.contains("bezig") || combined.contains("controle")
        || combined.contains("recherche") || combined.contains("reinigung")
        || combined.contains("pulizia") || combined.contains("スキャン")
        || combined.contains("검색") || combined.contains("szukanie")
        || combined.contains("limpeza") || combined.contains("limpieza")
        || combined.contains("очищення") || combined.contains("naar rommel zoeken")
        || combined.contains("zoeken naar bedreigingen") || combined.contains("searching for junk")
        || combined.contains("searching for threats") || combined.contains("checking performance")
        || combined.contains("checking apps") || combined.contains("checking clutter")

    if isScanning {
        let scanType = ScanType.detect(from: allTexts.joined(separator: " "))
        // Try to find percentage from window titles
        for text in allTexts {
            if let pct = extractPercentage(from: text) {
                currentProgressIsExact = true
                verboseLog("CGWindow: \(scanType.rawValue) at \(pct)%")
                return (true, scanType, pct)
            }
        }
        verboseLog("CGWindow: scanning detected (no percentage): \(scanType.rawValue)")
        return (true, scanType, 0)
    }

    // Check for completed scan
    if combined.contains("result") || combined.contains("review")
        || combined.contains("found") || combined.contains("items")
        || combined.contains("gevonden") || combined.contains("rommel") {
        let scanType = ScanType.detect(from: allTexts.joined(separator: " "))
        verboseLog("CGWindow: scan complete: \(scanType.rawValue)")
        return (true, scanType, 100)
    }

    return nil
}

/// Calculates execution progress for a given phase and elapsed time
private func execProgress(phase: Int, elapsed: TimeInterval) -> Int {
    switch phase {
    case 0: return min(15, Int((elapsed / 8.0) * 15))        // Cleanup: 0→15%
    case 1: return 15 + min(35, Int((elapsed / 12.0) * 35))  // Protection: 15→50%
    case 2: return 50 + min(15, Int((elapsed / 8.0) * 15))   // Performance: 50→65%
    case 3: return 65 + min(15, Int((elapsed / 8.0) * 15))   // Apps: 65→80%
    case 4: return 80 + min(15, Int((elapsed / 8.0) * 15))   // Clutter: 80→95%
    default: return 0
    }
}

/// Main detection function: finds CleanMyMac and reads its state.
/// Exact progress is passed through immediately. When CleanMyMac exposes only
/// a phase, the renderer uses an indeterminate bar instead of a fake percentage.
private func detectCleanMyMacState(cmmPID: pid_t? = nil) -> (isScanning: Bool, scanType: ScanType, progress: Int, isReady: Bool, isExecutionDone: Bool, junkSize: String?)? {
    guard var state = detectRawCleanMyMacState(cmmPID: cmmPID) else {
        return nil
    }

    // Terminal states must match CleanMyMac immediately; never animate a
    // synthetic fill after CleanMyMac has already finished.
    if state.isReady || state.isExecutionDone {
        state.progress = 100
        isAwaitingExecution = state.isReady
        return state
    }

    state.progress = min(state.progress, 99)
    return state
}

private func detectRawCleanMyMacState(cmmPID suppliedPID: pid_t? = nil) -> (isScanning: Bool, scanType: ScanType, progress: Int, isReady: Bool, isExecutionDone: Bool, junkSize: String?)? {
    currentProgressIsExact = false
    let cmmPID = suppliedPID ?? findCMMMainPID()
    if cmmPID > 0 { verboseLog("Found CleanMyMac pid=\(cmmPID)") }

    guard cmmPID > 0 else {
        scanStartTime = nil
        currentScanPhase = nil
        return nil
    }

    let axApp = AXUIElementCreateApplication(cmmPID)

    // Get all windows
    var windowList: AnyObject?
    AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
    let windows = windowList as? [AXUIElement] ?? []

    if windows.isEmpty {
        verboseLog("AXUIElement: no windows, trying CGWindowList fallback")
        if let fallbackState = detectViaCGWindow(pid: cmmPID) {
            return (fallbackState.isScanning, fallbackState.scanType, fallbackState.progress, false, false, nil)
        }
        verboseLog("No windows found via any method")
        return nil
    }

    // Collect all texts from ALL windows first, then detect
    var allTexts: [String] = []
    var effectiveModuleName: String?
    var moduleNameCandidate: String?
    var introTitleCandidate: String?
    var observedProgress: Int?
    for window in windows {
        let snapshot = collectAXWindowSnapshot(from: window)
        let texts = snapshot.texts
        if !texts.isEmpty {
            verboseLog("All text: \(texts.prefix(10))")
            allTexts.append(contentsOf: texts)
            let moduleName = snapshot.moduleName
            let introTitle = snapshot.introTitle
            if let moduleName { moduleNameCandidate = moduleName }
            if let introTitle { introTitleCandidate = introTitle }
            verboseLog("Module name: \(moduleName ?? "nil"), Intro title: \(introTitle ?? "nil")")
            if observedProgress == nil {
                observedProgress = snapshot.progress
                if observedProgress != nil { currentProgressIsExact = true }
            }
        }
    }
    
    // Use combined texts from all windows
    let texts = allTexts
    let combined = texts.joined(separator: " ").lowercased()
    // An intro title is the strongest signal that the user merely navigated
    // to a module. Prefer it over stale result labels and end any old session.
    effectiveModuleName = introTitleCandidate ?? moduleNameCandidate
    if let introTitleCandidate {
        verboseLog("Idle module intro: \(introTitleCandidate); resetting tracked activity")
        resetTrackedActivity()
        return nil
    }
    // Extract junk size (e.g., "738 MB", "1,5 GB", "1.5 GB") and shorten it
    var foundJunkSize: String?
    for t in texts {
        if let range = t.range(of: #"(\d+[\.,]?\d*)\s*(MB|GB|TB)"#, options: .regularExpression) {
            let match = String(t[range]).trimmingCharacters(in: .whitespaces)
            // Shorten: "1,5 GB" → "1.5G", "738 MB" → "738M"
            let shortened = match
                .replacingOccurrences(of: ",", with: ".")
                .replacingOccurrences(of: " GB", with: "G")
                .replacingOccurrences(of: " MB", with: "M")
                .replacingOccurrences(of: " TB", with: "T")
                .replacingOccurrences(of: "gb", with: "G")
                .replacingOccurrences(of: "mb", with: "M")
                .replacingOccurrences(of: "tb", with: "T")
            foundJunkSize = shortened
            break
        }
    }

    // My Clutter keeps its old "Digging through" accessibility nodes and a
    // stale 99% value after the visible results page is already ready. The
    // explicit results UI must win so the Notch can show its checkmark.
    if isMyClutterResultsPage(texts, moduleName: effectiveModuleName) {
        let finishedExecution = isInExecutionMode
        lastDetectionTime = Date()
        debugLog("My Clutter results page: \(finishedExecution ? "execution done" : "scan ready")")
        return (true, .myClutter, 100, !finishedExecution, finishedExecution, foundJunkSize)
    }
    if isSpaceLensResultsPage(texts, moduleName: effectiveModuleName) {
        let finishedExecution = isInExecutionMode
        lastDetectionTime = Date()
        debugLog("Space Lens results page: \(finishedExecution ? "execution done" : "scan ready")")
        return (true, .spaceLens, 100, !finishedExecution, finishedExecution, foundJunkSize)
    }

        // Detect scan phase based on keywords (supports all 12 CleanMyMac languages)
        // Smart Scan has 5 scanning phases:
        // 1. Cleanup (junk scanning)
        // 2. Protection (threat scanning)
        // 3. Performance (system examination)
        // 4. Apps (update checking)
        // 5. My Clutter (storage analysis)
        
        // Cleanup phase keywords (scanning only)
        let isCleanupPhase = combined.contains("naar rommel zoeken") || combined.contains("looking for junk")
            || combined.contains("searching for junk") || combined.contains("scanning for junk")
            || combined.contains("recherche de déchets") || combined.contains("nach müll suchen")
            || combined.contains("alla ricerca di sporco") || combined.contains("ジャンクを検索")
            || combined.contains("쓰레기 검색") || combined.contains("szukanie śmieci")
            || combined.contains("procurando por lixo") || combined.contains("buscando basura")
            || combined.contains("пошук сміття") || combined.contains("aan het zoeken naar rommel")
            || combined.contains("正在搜索垃圾")
        
        // Protection phase keywords (scanning only)
        let isProtectionPhase = combined.contains("zoeken naar bedreigingen") || combined.contains("looking for threats")
            || combined.contains("searching for threats") || combined.contains("scanning for threats")
            || combined.contains("recherche de menaces") || combined.contains("nach bedrohungen suchen")
            || combined.contains("alla ricerca di minacce") || combined.contains("脅威を検索")
            || combined.contains("위협 검색") || combined.contains("szukanie zagrożeń")
            || combined.contains("procurando por ameaças") || combined.contains("buscando amenazas")
            || combined.contains("пошук загроз") || combined.contains("aan het zoeken naar bedreigingen")
            || combined.contains("正在搜索威胁") || combined.contains("looking for malware")
            || combined.contains("recherche de logiciels malveillants") || combined.contains("nach malware suchen")
        
        // Performance phase keywords (scanning only)
        let isPerformancePhase = combined.contains("examining your system") || combined.contains("controllo delle prestazioni")
            || combined.contains("système en cours d") || combined.contains("überprüft ihr system")
            || combined.contains("votre système") || combined.contains("あなた の システム を 検査")
            || combined.contains("시스템 검사") || combined.contains("twoje system")
            || combined.contains("seu sistema") || combined.contains("tu sistema")
            || combined.contains("вашу систему") || combined.contains("uw systeem")
            || combined.contains("正在检查系统")
        
        // Apps phase keywords (scanning only)
        let isAppsPhase = combined.contains("looking for updates") || combined.contains("checking for updates")
            || combined.contains("recherche de mises à jour") || combined.contains("vérification des mises à jour")
            || combined.contains("nach updates suchen") || combined.contains("nach updates prüfen")
            || combined.contains("alla ricerca di aggiornamenti") || combined.contains("controllo aggiornamenti")
            || combined.contains("アップデートを検索") || combined.contains("アップデートを確認")
            || combined.contains("업데이트 검색") || combined.contains("업데이트 확인")
            || combined.contains("szukanie aktualizacji") || combined.contains("sprawdzanie aktualizacji")
            || combined.contains("procurando por atualizações") || combined.contains("verificando atualizações")
            || combined.contains("buscando actualizaciones") || combined.contains("comprobando actualizaciones")
            || combined.contains("пошук оновлень") || combined.contains("перевірка оновлень")
            || combined.contains("op zoek naar updates") || combined.contains("controleren op updates")
            || combined.contains("正在搜索更新") || combined.contains("正在检查更新")
        
        // My Clutter phase keywords (scanning only)
        let isClutterPhase = combined.contains("analyzing your storage") || combined.contains("analyse de votre stockage")
            || combined.contains("überprüft ihren speicher") || combined.contains("analisi del tuo archivio")
            || combined.contains("ストレージを分析") || combined.contains("스토리지 분석")
            || combined.contains("analiza twojego dysku") || combined.contains("analisando seu armazenamento")
            || combined.contains("analizando tu almacenamiento") || combined.contains("аналіз вашого сховища")
            || combined.contains("uw opslag analyseren") || combined.contains("正在分析存储")
        
        let isScanning = isCleanupPhase || isProtectionPhase || isPerformancePhase || isAppsPhase || isClutterPhase
        
        // Execution detection (after clicking Run)
        // Tiles show statuses like "Cleaning", "Done", etc. We count "done" tiles to determine phase.
        // Execution order: Cleanup → Security → System Tune-up → Installer → My Clutter
        
        let isExecPhase: Bool
        var isExecCleanup = false
        var isExecProtection = false
        var isExecPerformance = false
        var isExecApps = false
        var isExecClutter = false
        
        if isInExecutionMode {
            isExecPhase = true
            verboseLog("EXEC TEXTS: \(texts)")
            // Count individual done tiles (each text = one tile)
            var doneCount = 0
            for t in texts {
                let l = t.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if l == "done" || l == "klaar" || l == "terminé" || l == "fertig"
                    || l == "completato" || l == "完了" || l == "완료"
                    || l == "gotowe" || l == "feito" || l == "hecho" || l == "виконано"
                    || l == "nettoyé" || l == "bereinigt" || l == "pulito"
                    || l == "limpo" || l == "limpiado" || l == "очищено"
                    || l == "cleaned" || l == "opgeruimd" {
                    doneCount += 1
                } else if l.contains("your mac is safe") || l.contains("je mac is veilig")
                    || l.contains("mac est sûr") || l.contains("mac ist sicher")
                    || l.contains("mac è sicuro") {
                    doneCount += 1
                } else if l == "failed" || l == "mislukt" || l == "échoué"
                    || l == "fehlgeschlagen" || l == "non riuscito"
                    || l == "失敗" || l == "실패" {
                    doneCount += 1
                }
            }
            doneCount = min(doneCount, 5)
            verboseLog("Exec phase: doneCount=\(doneCount)")
            if doneCount <= 0 { isExecCleanup = true }
            else if doneCount == 1 { isExecProtection = true }
            else if doneCount == 2 { isExecPerformance = true }
            else if doneCount == 3 { isExecApps = true }
            else if doneCount >= 4 { isExecClutter = true }
        } else {
            isExecPhase = false
        }
        
        // Check if any tile shows an active execution status (not just results)
        let isActiveExecution = hasActiveOperation(in: texts)
        
        let isActive = isScanning || isActiveExecution || isExecPhase || isInExecutionMode

        // Track scan start time and phase
        if isActive {
            if let name = effectiveModuleName {
                let visibleType = ScanType.detect(from: name)
                if visibleType != .unknown, visibleType != detectedScanType {
                    detectedScanType = visibleType
                    debugLog("Visible module changed to \(visibleType.rawValue)")
                }
            }
            let isStorageScan = !isAwaitingExecution && !isInExecutionMode && isActiveExecution
                && [ScanType.myClutter, .spaceLens, .cloudCleanup].contains(detectedScanType)
            if isStorageScan {
                currentExecPhase = nil
            }
            var newPhase = "unknown"
            if isExecCleanup { newPhase = "exec-cleanup" }
            else if isExecProtection { newPhase = "exec-protection" }
            else if isExecPerformance { newPhase = "exec-performance" }
            else if isExecApps { newPhase = "exec-apps" }
            else if isExecClutter { newPhase = "exec-clutter" }
            else if isCleanupPhase { newPhase = "cleanup" }
            else if isProtectionPhase { newPhase = "protection" }
            else if isPerformancePhase { newPhase = "performance" }
            else if isAppsPhase { newPhase = "apps" }
            else if isClutterPhase { newPhase = "clutter" }
            else if isStorageScan { newPhase = "storage-scan" }
            else if isActiveExecution { newPhase = "executing" }
            else if isScanning { newPhase = "scanning" }
            
            // Detect execution start: scan completed, now tile activity begins
            // When we see active tile work (Cleaning, Removing etc.) but NOT scanning keywords,
            // it means the user clicked Run
            if !isInExecutionMode && isAwaitingExecution && isActiveExecution && !isScanning {
                scanStartTime = Date()
                executionStartTime = Date()
                isInExecutionMode = true
                isAwaitingExecution = false
                execPhaseIndex = 0
                lastPhaseAdvanceTime = Date()
                phaseStartTime = Date()
                currentExecPhase = "exec-cleanup"
                debugLog("Execution started via tile activity")
            }
            // Detect execution phase change - update phase but don't reset timer
            else if newPhase.hasPrefix("exec-") && newPhase != currentExecPhase {
                currentExecPhase = newPhase
                debugLog("Exec phase changed to \(newPhase)")
            }
            
            // If phase changed or scan just started, update tracking
            if scanStartTime == nil || newPhase != currentScanPhase {
                // Only set scanStartTime and detectedScanType on first detection
                if scanStartTime == nil {
                    scanStartTime = Date()
                    if let name = effectiveModuleName {
                        detectedScanType = ScanType.detect(from: name)
                    } else {
                        detectedScanType = ScanType.detect(from: texts.joined(separator: " "))
                    }
                    debugLog("Scan started: \(detectedScanType?.rawValue ?? "?")")
                } else if newPhase != currentScanPhase {
                    if let name = effectiveModuleName {
                        detectedScanType = ScanType.detect(from: name)
                    } else {
                        detectedScanType = ScanType.detect(from: texts.joined(separator: " "))
                    }
                    debugLog("Phase changed to \(newPhase), scan type: \(detectedScanType?.rawValue ?? "?")")
                }
                // Reset timer on every phase change so progress starts from base of new phase
                scanStartTime = Date()
                currentScanPhase = newPhase
                debugLog("Phase changed: \(newPhase)")
            }
            
            // Calculate progress
            let isExec = isInExecutionMode
            if isExec {
                let combined = texts.joined(separator: " ").lowercased()
                
                // Check if execution is COMPLETE (results page shown)
                let isComplete = combined.contains("well done") || combined.contains("goed gedaan")
                    || combined.contains("bien joué") || combined.contains("gut gemacht")
                    || combined.contains("ben fatto") || combined.contains("完璧")
                    || combined.contains("잘했어요") || combined.contains("dobrze")
                    || combined.contains("bem feito") || combined.contains("bien hecho")
                    || combined.contains("добре зроблено") || combined.contains("start over")
                    || combined.contains("begin opnieuw") || combined.contains("recommencer")
                    || combined.contains("neu starten") || combined.contains("ricomincia")
                    || combined.contains("다시 시작") || combined.contains("zacznij od nowa")
                    || combined.contains("começar novamente") || combined.contains("empezar de nuevo")
                    || combined.contains("почати заново")
                
                if isComplete {
                    debugLog("Execution complete!")
                    lastDetectionTime = Date()
                    let scanType = detectedScanType ?? ScanType.detect(from: texts.joined(separator: " "))
                    return (true, scanType, 100, false, true, foundJunkSize)
                }
                
                // Detect which phase is ACTIVE based on tile action titles
                var cleanupActive = false
                var protectionActive = false
                var performanceActive = false
                var appsActive = false
                var clutterActive = false
                
                // Cleanup tile: "Cleaning junk" / "Opruimen van rommel" etc.
                cleanupActive = combined.contains("cleaning junk") || combined.contains("opr uimen van rommel")
                    || combined.contains("nettoyage des ordures") || combined.contains("aufräumen von müll")
                    || combined.contains("pulizia degli sporchi") || combined.contains("limpando a sujeira")
                    || combined.contains("limpiando laChair") || combined.contains("очистка мусора")
                    || combined.contains("정크 정리") || combined.contains("усунення сміття")
                    || combined.contains("czyszczenie") || combined.contains("usuwania śmieci")
                
                // Protection tile: only ACTIVE keywords (not result texts like "No threats")
                protectionActive = combined.contains("removing threat") || combined.contains("removing your threat")
                    || combined.contains("bedreigingen verwijderen")
                    || combined.contains("suppression des menaces") || combined.contains("entfernung von bedrohungen")
                    || combined.contains("rimozione delle minacce") || combined.contains("removendo ameaças")
                    || combined.contains("eliminando amenazas") || combined.contains("видалення загроз")
                    || combined.contains("위협 제거") || combined.contains("usuwanie zagrożeń")
                    || combined.contains("remoção de ameaças")
                    || combined.contains("checking protection") || combined.contains("bescherming controleren")
                    || combined.contains("vérification de la protection") || combined.contains("überprüfung des schutzes")
                    || combined.contains("controllo della protezione") || combined.contains("verificação da proteção")
                    || combined.contains("scanning for threat") || combined.contains("scan of bedreigingen")
                    || combined.contains("recherche de menaces") || combined.contains("suche nach bedrohungen")
                    || combined.contains("ricerca delle minacce") || combined.contains("procurando ameaças")
                    || combined.contains("buscando amenazas") || combined.contains("пошук загроз")
                    || combined.contains("위협 검색") || combined.contains("szukanie zagrożeń")
                    || combined.contains("procurando por ameaças")
                
                // Performance tile: "Running your tasks" / "Je taken uitvoeren" etc.
                performanceActive = combined.contains("running your task") || combined.contains("running task")
                    || combined.contains("taken uitvoeren") || combined.contains("je taken uitvoeren")
                    || combined.contains("exécution des tâches") || combined.contains("ausführung von aufgaben")
                    || combined.contains("esecuzione delle attività") || combined.contains("executando tarefas")
                    || combined.contains("ejecutando tareas") || combined.contains("виконання завдань")
                    || combined.contains("작업 실행") || combined.contains("wykonywanie zadań")
                    || combined.contains("execução de tarefas")
                
                // Apps tile: "Installing updates" / "Updates installeren" etc.
                appsActive = combined.contains("installing update") || combined.contains("updates installeren")
                    || combined.contains("installation des mises") || combined.contains("installation von updates")
                    || combined.contains("installazione degli aggiornamenti") || combined.contains("instalando atualizações")
                    || combined.contains("instalando actualizaciones") || combined.contains("встановлення оновлень")
                    || combined.contains("업데이트 설치") || combined.contains("instalowanie aktualizacji")
                    || combined.contains("instalação de atualizações")
                
                // My Clutter tile: "Decluttering" / "Opruimen" etc.
                clutterActive = combined.contains("decluttering") || combined.contains("desordenando")
                    || combined.contains("désencombrement") || combined.contains("aufräumen")
                    || combined.contains("disordinando") || combined.contains("desimprensando")
                    || combined.contains("despejando") || combined.contains("розчищення")
                    || combined.contains("정리 정돈") || combined.contains("odkamienianie")
                    || combined.contains("desobstruindo")
                
                // Determine current phase from active titles
                var targetPhase = 0
                if cleanupActive { targetPhase = 0 }
                if protectionActive { targetPhase = 1 }
                if performanceActive { targetPhase = 2 }
                if appsActive { targetPhase = 3 }
                if clutterActive { targetPhase = 4 }
                
                // Advance at most one phase per 1.5s (match CleanMyMac execution speed)
                let now = Date()
                if targetPhase > execPhaseIndex {
                    let timeSinceLastAdvance = now.timeIntervalSince(lastPhaseAdvanceTime)
                    if timeSinceLastAdvance >= 1.5 {
                        let oldPhase = execPhaseIndex
                        execPhaseIndex = targetPhase
                        lastPhaseAdvanceTime = now
                        phaseStartTime = now  // Reset timer for new phase
                        debugLog("Exec phase \(oldPhase)→\(targetPhase)")
                    }
                }

                // Time-based progress within current phase.
                // Smoothing (1% steps) is applied centrally in detectCleanMyMacState().
                let elapsed = now.timeIntervalSince(phaseStartTime)
                let progress = observedProgress ?? execProgress(phase: execPhaseIndex, elapsed: elapsed)
                
                verboseLog("Exec active: cleanup=\(cleanupActive) protection=\(protectionActive) perf=\(performanceActive) apps=\(appsActive) clutter=\(clutterActive) → phase=\(execPhaseIndex) progress=\(progress)%")
                lastDetectionTime = Date()
                let scanType = detectedScanType ?? ScanType.detect(from: texts.joined(separator: " "))
                return (true, scanType, progress, false, false, foundJunkSize)
            }
            
            let elapsed = Date().timeIntervalSince(scanStartTime ?? Date())
            
            // Time-based progress within current phase.
            // Smoothing (1% steps) is applied centrally in detectCleanMyMacState().
            let progress: Int
            if let observedProgress {
                progress = min(99, max(0, observedProgress))
            } else if let st = detectedScanType,
                      [.myClutter, .spaceLens, .cloudCleanup].contains(st) {
                progress = estimatedStorageProgress(scanType: st, elapsed: elapsed)
            } else if let st = detectedScanType, st != .smartScan {
                progress = min(95, Int((elapsed / 60.0) * 95))
            } else if isCleanupPhase {
                progress = min(15, Int((elapsed / 15.0) * 15))
            } else if isProtectionPhase {
                progress = 15 + min(35, Int((elapsed / 45.0) * 35))
            } else if isPerformancePhase {
                progress = min(65, 50 + Int((elapsed / 15.0) * 15))
            } else if isAppsPhase {
                progress = min(80, 65 + Int((elapsed / 15.0) * 15))
            } else if isClutterPhase {
                progress = min(95, 80 + Int((elapsed / 15.0) * 15))
            } else if isScanning {
                progress = min(5, Int((elapsed / 15.0) * 5))
            } else {
                progress = 0
            }
            
            lastDetectionTime = Date()
            let scanType = detectedScanType ?? ScanType.detect(from: texts.joined(separator: " "))
            verboseLog("Scanning detected: \(scanType.rawValue) phase=\(currentScanPhase ?? "?") progress=\(progress)%")
            return (true, scanType, progress, false, false, foundJunkSize)
        }
        
        // Check for active task execution FIRST (before scan completion)
        // During execution, "start over" keywords are also visible, so we must check execution first
        if scanStartTime != nil && (isExecPhase || isInExecutionMode) {
            // Check if any tile is showing an active status
            let tileStatuses = texts.filter { $0.contains("Cleaning") || $0.contains("Removing") 
                || $0.contains("Checking") || $0.contains("Scanning") || $0.contains("Analyzing")
                || $0.contains("Processing") || $0.contains("Started")
                || $0.contains("Done") || $0.contains("Failed") || $0.contains("Cleaned")
                || $0.contains("No threats") || $0.contains("No junk") || $0.contains("Optimized")
                || $0.contains("Opruimen") || $0.contains("Verwijderen") || $0.contains("Controleren")
                || $0.contains("Scannen") || $0.contains("Analyseren") || $0.contains("Verwerken")
                || $0.contains("Gestart") || $0.contains("Klaar") || $0.contains("Gevonden")
                || $0.contains("Geen bedreigingen") || $0.contains("Geen rommel")
                || $0.contains("Nettoyage") || $0.contains("Suppression") || $0.contains("Vérification")
                || $0.contains("Scan") || $0.contains("Analyse") || $0.contains("Traitement")
                || $0.contains("Terminé") || $0.contains("Échoué") || $0.contains("Aucune menace")
                || $0.contains("Reinigung") || $0.contains("Entfernung") || $0.contains("Überprüfung")
                || $0.contains("Analyse") || $0.contains("Verarbeitung")
                || $0.contains("Fertig") || $0.contains("Fehlgeschlagen") || $0.contains("Keine Bedrohungen")
                || $0.contains("Pulizia") || $0.contains("Rimozione") || $0.contains("Controllo")
                || $0.contains("Scansione") || $0.contains("Analisi") || $0.contains("Elaborazione")
                || $0.contains("Completato") || $0.contains("Non riuscito") || $0.contains("Nessuna minaccia") }
            
            if !tileStatuses.isEmpty {
                let scanType = detectedScanType ?? {
                    if let name = effectiveModuleName {
                        return ScanType.detect(from: name)
                    }
                    return ScanType.detect(from: texts.joined(separator: " "))
                }()
                // Simple time-based progress during execution
                let elapsed = Date().timeIntervalSince(executionStartTime ?? Date())
                let progress = min(95, Int((elapsed / executionDuration) * 95))
                verboseLog("Task execution detected: \(scanType.rawValue) phase=\(currentScanPhase ?? "?") progress=\(progress)% elapsed=\(String(format: "%.1f", elapsed))s")
                
                // Check if execution is done: all tiles show final status AND enough time has passed
                // Also check that we see results keywords (not just "Done" from a single completed tile)
                let hasActiveStatus = texts.contains { $0.contains("Cleaning") || $0.contains("Removing") 
                    || $0.contains("Checking") || $0.contains("Scanning") || $0.contains("Analyzing")
                    || $0.contains("Processing") || $0.contains("Started")
                    || $0.contains("aan het") || $0.contains("en cours") || $0.contains("wird")
                    || $0.contains("in corso") || $0.contains("中") || $0.contains("검색")
                    || $0.contains("czyszczenie") || $0.contains("usuwanie") || $0.contains("sprawdzanie")
                    || $0.contains("limpando") || $0.contains("removendo") || $0.contains("verificando")
                    || $0.contains("analisando") || $0.contains("limpiando") || $0.contains("comprobando")
                    || $0.contains("очищення") || $0.contains("видалення") || $0.contains("перевірка") }
                let hasFinalResults = texts.contains { $0.contains("Done") || $0.contains("Cleaned")
                    || $0.contains("No threats") || $0.contains("No junk") || $0.contains("Failed")
                    || $0.contains("Optimized") || $0.contains("No updates")
                    || $0.contains("Geen bedreigingen") || $0.contains("Geen rommel") || $0.contains("Geoptimaliseerd")
                    || $0.contains("Aucune menace") || $0.contains("Aucun déchet") || $0.contains("Optimisé")
                    || $0.contains("Keine Bedrohungen") || $0.contains("Kein Müll") || $0.contains("Optimiert")
                    || $0.contains("Nessuna minaccia") || $0.contains("Nessuno sporco") || $0.contains("Ottimizzato") }
                let timeUp = elapsed >= executionDuration
                // Done only when: enough time passed, no active work, and we see final results
                let isDone = timeUp && !hasActiveStatus && hasFinalResults
                
                return (true, scanType, isDone ? 100 : progress, false, isDone, foundJunkSize)
            }
        }

        // Check for scan completed (results page) - only if NOT in execution mode
        if scanStartTime != nil && !isInExecutionMode && (
            combined.contains("begin opnieuw") || combined.contains("start over")
            || combined.contains("kijk wat we hebben gevonden") || combined.contains("see what we found")
            || combined.contains("taken kunnen") || combined.contains("tasks can")
            || combined.contains("recommencer") || combined.contains("erneut beginnen")
            || combined.contains("ricomincia") || combined.contains("もう一度開始")
            || combined.contains("다시 시작") || combined.contains("zacznij od nowa")
            || combined.contains("começar novamente") || combined.contains("empezar de nuevo")
            || combined.contains("почати заново") || combined.contains("voir ce que nous avons trouvé")
            || combined.contains("sehen Sie, was wir gefunden haben") || combined.contains("vedi cosa abbiamo trovato")
            || combined.contains("見つけたものを見る") || combined.contains("발견한 것 보기")
            || combined.contains("zobacz, co znaleźliśmy") || combined.contains("veja o que encontramos")
            || combined.contains("ver lo que hemos encontrado") || combined.contains("подивитися, що ми знайшли")
            || combined.contains("well done") || combined.contains("goed gedaan")
            || combined.contains("bien joué") || combined.contains("gut gemacht")
            || combined.contains("ben fatto") || combined.contains("よくできました")
            || combined.contains("잘했어요") || combined.contains("dobrze")
            || combined.contains("bem feito") || combined.contains("bien hecho")
            || combined.contains("добре зроблено")) {
            let scanType = detectedScanType ?? {
                if let name = effectiveModuleName {
                    return ScanType.detect(from: name)
                }
                return ScanType.detect(from: texts.joined(separator: " "))
            }()
            debugLog("Scan complete (ready): \(scanType.rawValue)")
            // If in execution mode, this is execution completion (show "Done" + dismiss)
            if isInExecutionMode {
                scanStartTime = Date()
                return (true, scanType, 100, false, true, foundJunkSize)
            }
            // If we see tile results (Cleaned, Done, etc.) it means tasks were executed
            let hasTileResults = texts.contains { $0 == "Cleaned" || $0 == "Done"
                || $0 == "Klaar" || $0 == "Terminé" || $0 == "Fertig"
                || $0.contains("Your Mac is safe") || $0.contains("No threats to remove") }
            if hasTileResults {
                scanStartTime = Date()
                return (true, scanType, 100, false, true, foundJunkSize)
            }
            // First scan completed, show "Ready" and wait for user to run tasks
            scanStartTime = Date()
            return (true, scanType, 100, true, false, foundJunkSize)
        }

    // If we were scanning and now no text detected, keep state briefly
    if let startTime = scanStartTime, let phase = currentScanPhase, let lastDetect = lastDetectionTime {
        let sinceLastDetect = Date().timeIntervalSince(lastDetect)
        if sinceLastDetect < 2.0 {
            let elapsed = Date().timeIntervalSince(startTime)
            let progress: Int
            switch phase {
            case "cleanup":     progress = min(15, Int((elapsed / 13.0) * 15))
            case "protection":  progress = 15 + min(35, Int((max(0, elapsed - 13.0) / 57.0) * 35))
            case "performance": progress = 50 + min(15, Int((max(0, elapsed - 70.0) / 15.0) * 15))
            case "apps":        progress = 65 + min(15, Int((max(0, elapsed - 85.0) / 15.0) * 15))
            case "clutter":     progress = 80 + min(15, Int((max(0, elapsed - 100.0) / 15.0) * 15))
            default:            progress = min(95, Int((elapsed / 30.0) * 95))
            }
            let scanType: ScanType = detectedScanType ?? .unknown
            verboseLog("Keeping last scan state: \(scanType.rawValue) phase=\(phase) progress=\(progress)%")
            return (true, scanType, progress, false, false, foundJunkSize)
        }
    }

    verboseLog("No scan state detected")
    resetTrackedActivity()
    return nil
}

// MARK: - JSON Payload Builder

private func dismissPayload() -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": "dismiss-\(Int(Date().timeIntervalSince1970))",
        "type": "dismiss",
        "activityID": activityID
    ]
}

private func showSneakPeekPayload() -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": "showSneakPeek-\(Int(Date().timeIntervalSince1970))",
        "type": "showSneakPeek",
        "activityID": activityID
    ]
}

private func closeSneakPeekPayload() -> [String: Any] {
    [
        "schemaVersion": schemaVersion,
        "requestID": "closeSneakPeek-\(Int(Date().timeIntervalSince1970))",
        "type": "closeSneakPeek",
        "activityID": activityID
    ]
}

private var moduleIconBase64Cache: [String: String] = [:]

/// Compact Live Activities reject `packageFile` images in DynamicLake 1.9.7.5,
/// so module artwork must be embedded as bounded inline PNG data there.
private func inlineModuleIconPayload(scanType: ScanType, id: String) -> [String: Any]? {
    let assetFile = scanType.assetFile
    if let encoded = moduleIconBase64Cache[assetFile] {
        return [
            "type": "image", "id": id,
            "source": "inlineData", "mimeType": "image/png", "base64Data": encoded
        ]
    }

    let environment = ProcessInfo.processInfo.environment
    var roots: [URL] = []
    for key in [pluginPackageEnvironmentKey, pluginPackagePathEnvironmentKey] {
        if let path = environment[key], !path.isEmpty {
            roots.append(URL(fileURLWithPath: path, isDirectory: true))
        }
    }
    roots.append(URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent())
    roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))

    for root in roots {
        let url = root.appendingPathComponent(assetFile)
        guard let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= 48 * 1024,
              data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { continue }
        let encoded = data.base64EncodedString()
        moduleIconBase64Cache[assetFile] = encoded
        return [
            "type": "image", "id": id,
            "source": "inlineData", "mimeType": "image/png", "base64Data": encoded
        ]
    }
    return nil
}

/// CleanMyMac 5 does not expose a numeric percentage for every scan. In that
/// case use stable phase checkpoints: the indicator moves only when the app
/// itself advances, rather than spinning or drifting on a timer.
private func phaseAlignedProgress(_ phase: String) -> Int {
    switch phase {
    case "cleanup", "exec-cleanup": return 10
    case "protection", "exec-protection": return 35
    case "performance", "exec-performance": return 58
    case "apps", "exec-apps": return 74
    case "clutter", "exec-clutter": return 88
    case "scanning", "storage-scan", "executing": return 50
    default: return 8
    }
}

private func activityPayload(
    commandType: String,
    scanType: ScanType,
    progress: Int,
    settings: PluginSettings,
    progressIsExact: Bool = false,
    isIdle: Bool = false,
    isReady: Bool = false,
    currentAction: String? = nil,
    junkSize: String? = nil
) -> [String: Any] {
    let color = scanType.color
    let label = scanType.rawValue
    let percentText: String
    let status: String
    
    if isIdle {
        percentText = "Idle"
        status = "success"
    } else if isReady {
        percentText = "Ready"
        status = "success"
    } else if progress >= 100 {
        percentText = "Done"
        status = "success"
    } else {
        percentText = ""
        status = "inProgress"
    }

    let compactRightSlot: [String: Any] = {
        if settings.compactPresentation == .moduleIcon {
            if isIdle {
                return [
                    "type": "image", "id": "cmm-compact-idle",
                    "source": "sfSymbol", "systemImage": "pause.fill", "tint": color
                ]
            }
            if isReady || progress >= 100 {
                return [
                    "type": "image", "id": "cmm-compact-complete",
                    "source": "sfSymbol", "systemImage": "checkmark", "tint": color
                ]
            }
        } else if isIdle || isReady || progress >= 100 {
            return [
                "type": "text", "id": "cmm-percent",
                "text": percentText, "style": "marquee", "tint": color
            ]
        }
        var progressSlot: [String: Any] = [
            "type": "progress",
            "status": status,
            "tint": color
        ]
        if progressIsExact {
            progressSlot["value"] = Double(progress) / 100.0
        }
        return progressSlot
    }()

    // A frame may contain at most 64 KiB. Avoid embedding the same PNG twice:
    // icon mode reserves official artwork for compact; text mode uses it in Sneak Peek.
    let sneakLeft: [String: Any]
    switch settings.compactPresentation {
    case .moduleIcon:
        sneakLeft = [
            "type": "image", "id": "cmm-sneak-module-symbol",
            "source": "sfSymbol", "systemImage": scanType.icon, "tint": color
        ]
    case .moduleName:
        sneakLeft = inlineModuleIconPayload(
            scanType: scanType,
            id: "cmm-module-icon"
        ) ?? [
            "type": "image", "id": "cmm-module-icon-fallback",
            "source": "sfSymbol", "systemImage": scanType.icon, "tint": color
        ]
    }

    let sneakCenter: [String: Any]? = if let action = currentAction {
        ["type": "text", "id": "cmm-action",
         "text": action, "style": "marquee", "tint": color]
    } else {
        nil
    }

    let compactLeftSlot: [String: Any]
    switch settings.compactPresentation {
    case .moduleIcon:
        compactLeftSlot = inlineModuleIconPayload(
            scanType: scanType,
            id: "cmm-compact-module-icon"
        ) ?? [
            "type": "text", "id": "cmm-label-fallback",
            "text": label, "style": "marquee", "tint": color
        ]
    case .moduleName:
        compactLeftSlot = [
            "type": "text", "id": "cmm-label",
            "text": label, "style": "marquee", "tint": color
        ]
    }

    let compactSurface: [String: Any] = [
        "leftSlot": compactLeftSlot,
        "rightSlot": compactRightSlot
    ]

    let sneakRight: [String: Any] = {
        let symbol: String
        if isIdle {
            symbol = "pause.circle.fill"
        } else if isReady || currentAction == "Done" {
            symbol = "checkmark.circle.fill"
        } else if isInExecutionMode {
            switch currentExecPhase {
            case "exec-cleanup": symbol = "trash.fill"
            case "exec-protection": symbol = "lock.shield.fill"
            case "exec-performance": symbol = "gauge.with.dots.needle.67percent"
            case "exec-apps": symbol = "app.badge.checkmark"
            case "exec-clutter": symbol = "externaldrive.fill"
            default: symbol = "hammer.fill"
            }
        } else if let phase = currentScanPhase {
            switch phase {
            case "cleanup": symbol = "trash.fill"
            case "protection": symbol = "lock.shield.fill"
            case "performance": symbol = "gauge.with.dots.needle.67percent"
            case "apps": symbol = "app.badge.checkmark"
            case "clutter": symbol = "externaldrive.fill"
            default: symbol = "questionmark.circle"
            }
        } else {
            symbol = "questionmark.circle"
        }
        return ["type": "status", "id": "cmm-phase",
                "systemImage": symbol, "tint": color]
    }()

    var sneakPeek: [String: Any] = [
        "leftSlot": sneakLeft,
        "rightSlot": sneakRight
    ]
    if let center = sneakCenter {
        sneakPeek["center"] = center
    }

    return [
        "schemaVersion": schemaVersion,
        "requestID": "\(commandType)-\(Int(Date().timeIntervalSince1970))",
        "type": commandType,
        "activityID": activityID,
        "title": pluginName,
        "priority": "normal",
        "size": settings.compactPresentation == .moduleIcon ? "small" : "large",
        "surfaces": [
            "compactLiveActivity": compactSurface,
            "sneakPeek": sneakPeek
        ]
    ]
}

// MARK: - Plugin Main

private enum MonitoringMode: String {
    case appClosed
    case appIdle
    case active
}

private func pollingInterval(for mode: MonitoringMode, settings: PluginSettings) -> TimeInterval {
    switch mode {
    case .appClosed: return 15
    case .appIdle: return 2
    case .active: return settings.pollSeconds
    }
}

private final class CleanMyMacPlugin {
    private let client: JSONSocketClient
    private let queue = DispatchQueue(label: "com.dynamiclake.cleanmymac.plugin")
    private var published = false
    private var lastSignature: String?
    private var settings = PluginSettings()
    private var lastSettingsCheck = Date.distantPast
    private var monitoringMode: MonitoringMode = .appClosed
    private var currentTimerInterval: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var dismissWorkItem: DispatchWorkItem?
    private var axObserver: AXObserver?
    private var axRunLoopSource: CFRunLoopSource?
    private var axWatchedPID: pid_t = 0
    private var eventTickPending = false
    private var lastFullTick = Date.distantPast
    private var lastSendTime = Date.distantPast  // Rate-limit guard for update sends
    private var workspaceObservers: [NSObjectProtocol] = []

    init(client: JSONSocketClient) { self.client = client }

    func run() throws {
        debugLog("starting plugin socket=\(client.socketPath)")
        try client.connect()
        debugLog("connected")

        settings = loadSettings()
        lastSettingsCheck = Date()
        setupWorkspaceObservers()
        scheduleTimer(interval: pollingInterval(for: .appClosed, settings: settings))
        queue.async { [weak self] in self?.tick() }
        CFRunLoopRun()
    }

    private func scheduleTimer(interval: TimeInterval) {
        guard currentTimerInterval != interval else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let leeway = min(1, max(0.1, interval * 0.15))
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(leeway * 1_000)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer?.cancel()
        timer = t
        currentTimerInterval = interval
        debugLog("monitor mode=\(monitoringMode.rawValue) interval=\(String(format: "%.2f", interval))s")
    }

    private func setMonitoringMode(_ mode: MonitoringMode) {
        monitoringMode = mode
        scheduleTimer(interval: pollingInterval(for: mode, settings: settings))
    }

    private func refreshSettingsIfNeeded() {
        guard Date().timeIntervalSince(lastSettingsCheck) >= 5 else { return }
        lastSettingsCheck = Date()
        let updated = loadSettings()
        guard updated != settings else { return }
        settings = updated
        lastSignature = nil
        currentTimerInterval = nil
        scheduleTimer(interval: pollingInterval(for: monitoringMode, settings: settings))
        debugLog("settings reloaded")
    }

    private func currentActionText() -> String? {
        if isInExecutionMode {
            switch execPhaseIndex {
            case 0: return "Cleaning junk"
            case 1: return "Removing threats"
            case 2: return "Running your tasks"
            case 3: return "Updating apps"
            case 4: return "Decluttering"
            default: return nil
            }
        }
        if let phase = currentScanPhase {
            switch phase {
            case "cleanup": return "Looking for junk"
            case "protection": return "Looking for threats"
            case "performance": return "Examining system"
            case "apps": return "Checking for updates"
            case "clutter": return "Analyzing storage"
            case "storage-scan":
                switch detectedScanType {
                case .myClutter: return "Digging through files"
                case .spaceLens: return "Analyzing disk space"
                case .cloudCleanup: return "Scanning cloud storage"
                default: return "Scanning"
                }
            default: return nil
            }
        }
        return nil
    }

    private func tick() {
        lastFullTick = Date()
        handleCallbacks()
        refreshSettingsIfNeeded()

        // Detect scan complete: show sneak peek when "Ready" appears
        // (handled in the isReady block below)

        let cmmPID = findCMMMainPID()
        if axWatchedPID != 0, kill(axWatchedPID, 0) != 0 {
            cleanupAXObserver()
        }
        if cmmPID > 0, axWatchedPID != cmmPID {
            setupAXObserver(pid: cmmPID)
        }

        guard let state = detectCleanMyMacState(cmmPID: cmmPID) else {
            setMonitoringMode(cmmPID > 0 ? .appIdle : .appClosed)
            if settings.showOnIdle, cmmPID > 0 {
                let sig = "idle|\(settings.compactPresentation.rawValue)"
                if sig != lastSignature {
                    let cmd = published ? "update" : "create"
                    do {
                        try client.send(activityPayload(
                            commandType: cmd,
                            scanType: .smartScan,
                            progress: 0,
                            settings: settings,
                            isIdle: true,
                            currentAction: "CleanMyMac is idle"
                        ))
                        debugLog("sent \(cmd) idle")
                        published = true
                        lastSignature = sig
                    } catch {
                        debugLog("send error: \(error)")
                    }
                }
            } else if published {
                hideActivity()
                lastSignature = nil
            }
            return
        }
        
        // If execution is done (all tiles final), show "Done" and schedule dismiss
        if state.isExecutionDone {
            setMonitoringMode(.appIdle)
            let sig = "\(state.scanType.rawValue)|done"
            if sig != lastSignature {
                let cmd = published ? "update" : "create"
                do {
                    try client.send(activityPayload(commandType: cmd, scanType: state.scanType, progress: 100, settings: settings, currentAction: isInExecutionMode ? "Done" : nil))
                    debugLog("sent \(cmd) \(state.scanType.rawValue) Done (execution complete)")
                    published = true
                    lastSignature = sig
                    isInExecutionMode = false  // Reset execution mode
                } catch {
                    debugLog("send error: \(error)")
                }
            }
            if dismissWorkItem == nil {
                debugLog("execution complete, scheduling dismiss in 5s")
                scheduleDismiss()
            }
            return
        }

        // If scan is complete (100%), show "Ready" and wait for user to run tasks
        if state.progress >= 100 || state.isReady {
            setMonitoringMode(.appIdle)
            // Cancel any pending dismiss - we want to stay visible
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            
            let sig = "\(state.scanType.rawValue)|ready"
            // Always force progress to 100 when ready
            let readyProgress = state.isReady ? 100 : state.progress
            if sig != lastSignature {
                let cmd = published ? "update" : "create"
                do {
                    try client.send(activityPayload(commandType: cmd, scanType: state.scanType, progress: readyProgress, settings: settings, isReady: true, currentAction: "Ready to run"))
                    debugLog("sent \(cmd) \(state.scanType.rawValue) Ready (progress=\(readyProgress)%)")
                    published = true
                    lastSignature = sig
                } catch {
                    debugLog("send error: \(error)")
                }
            }
            return
        }

        // Cancel any pending dismiss if scan is still running
        setMonitoringMode(.active)
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let phase = currentExecPhase ?? currentScanPhase ?? "active"
        let usesStorageEstimate = !currentProgressIsExact && phase == "storage-scan"
        let displayedProgress = currentProgressIsExact || usesStorageEstimate
            ? state.progress
            : phaseAlignedProgress(phase)
        let sig = "\(state.scanType.rawValue)|\(phase)|\(displayedProgress)"
        guard sig != lastSignature else { return }

        // Rate-limit guard: DynamicLake drops updates sent too fast.
        // Terminal/create payloads bypass this (sent from their own branches).
        guard Date().timeIntervalSince(lastSendTime) >= 0.25 else { return }

        let cmd = published ? "update" : "create"
        do {
            try client.send(activityPayload(
                commandType: cmd,
                scanType: state.scanType,
                progress: displayedProgress,
                settings: settings,
                progressIsExact: true,
                currentAction: currentActionText()
            ))
            let progressSource = currentProgressIsExact ? "exact" : (usesStorageEstimate ? "storage-estimate" : "phase")
            debugLog("sent \(cmd) \(state.scanType.rawValue) progress=\(displayedProgress)% source=\(progressSource) phase=\(phase)")
            published = true
            lastSignature = sig
            lastSendTime = Date()
        } catch {
            debugLog("send error: \(error)")
        }
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideActivity()
        }
        dismissWorkItem = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func handleCallbacks() {
        for msg in client.receiveAvailable() {
            debugLog("received: \(msg)")
            guard msg["type"] as? String == "action" else { continue }
            guard let actionID = msg["actionID"] as? String else { continue }
            if actionID == "dismiss" {
                published = false
                debugLog("dismissed by DynamicLake")
            }
        }
    }

    private func hideActivity() {
        do {
            try client.send(dismissPayload())
            debugLog("sent dismiss")
        } catch {
            debugLog("dismiss error: \(error)")
        }
        published = false
        resetTrackedActivity()
    }

    // MARK: - Application lifecycle

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let launched = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  cmmMainBundleIDs.contains(bundleID) else { return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                invalidateCMMMainPIDCache()
                cachedCMMMainPID = app.processIdentifier
                lastCMMProcessScan = Date()
                self.setMonitoringMode(.appIdle)
                self.tick()
            }
        }
        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  cmmMainBundleIDs.contains(bundleID) else { return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                invalidateCMMMainPIDCache()
                self.cleanupAXObserver()
                if self.published { self.hideActivity() }
                self.lastSignature = nil
                self.setMonitoringMode(.appClosed)
            }
        }
        workspaceObservers = [launched, terminated]
    }

    // MARK: - AXObserver (event-driven updates)

    private func setupAXObserver(pid cmmPID: pid_t) {
        guard cmmPID > 0 else { return }
        if axWatchedPID != 0 { cleanupAXObserver() }

        var observer: AXObserver?
        let result = AXObserverCreate(cmmPID, { _, element, _, _ in
            // UI changed — trigger a coalesced near-immediate update.
            if let plugin = runningPlugin {
                plugin.requestEventTick()
            }
        }, &observer)

        guard result == .success, let obs = observer else {
            debugLog("AXObserver create failed: \(result.rawValue)")
            return
        }

        // Watch both value and structural changes. CleanMyMac replaces phase
        // views while scanning, so value-only observation can miss transitions.
        let axApp = AXUIElementCreateApplication(cmmPID)
        let notifications: [CFString] = [
            kAXValueChangedNotification as CFString,
            kAXLayoutChangedNotification as CFString,
            kAXCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXFocusedUIElementChangedNotification as CFString
        ]
        for notification in notifications {
            let addResult = AXObserverAddNotification(obs, axApp, notification, nil)
            if addResult != .success && addResult != .notificationAlreadyRegistered {
                debugLog("AXObserver notification \(notification) failed: \(addResult.rawValue)")
            }
        }

        let source = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        CFRunLoopWakeUp(CFRunLoopGetMain())

        axObserver = obs
        axRunLoopSource = source
        axWatchedPID = cmmPID
        debugLog("AXObserver attached to pid=\(cmmPID)")
    }

    private func requestEventTick() {
        queue.async { [weak self] in
            guard let self, !self.eventTickPending else { return }
            self.eventTickPending = true
            let minimumSpacing: TimeInterval = self.monitoringMode == .active ? 0.20 : 0.75
            let elapsed = Date().timeIntervalSince(self.lastFullTick)
            let delay = max(0.15, minimumSpacing - elapsed)
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.eventTickPending = false
                self.tick()
            }
        }
    }

    private func cleanupAXObserver() {
        if axWatchedPID != 0 {
            if let source = axRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            axRunLoopSource = nil
            axObserver = nil
            axWatchedPID = 0
            debugLog("AXObserver detached")
        }
    }
}

// MARK: - Entry Point

private var runningPlugin: CleanMyMacPlugin?

@main
private enum Main {
    static func main() {
        let args = Set(CommandLine.arguments.dropFirst())

        if args.contains("--self-test") {
            let cases: [(String, ScanType)] = [
                ("Smart Care", .smartScan),
                ("Cleanup", .systemJunk),
                ("Protection", .malware),
                ("Performance", .optimize),
                ("Applications", .uninstaller),
                ("My Clutter", .myClutter),
                ("Space Lens", .spaceLens),
                ("Cloud Cleanup", .cloudCleanup)
            ]
            for (input, expected) in cases {
                let actual = ScanType.detect(from: input)
                guard actual == expected else {
                    fputs("Self-test failed: \(input) -> \(actual.rawValue), expected \(expected.rawValue)\n", stderr)
                    exit(1)
                }
            }
            guard ScanType.smartScan.assetFile == "Assets/CleanMyMac-Smart-Care.png" else {
                fputs("Self-test failed: Smart Care artwork mapping\n", stderr)
                exit(1)
            }
            guard ScanType.smartScan.color == "purple", ScanType.malware.color == "pink" else {
                fputs("Self-test failed: Smart Care logo-matched tint\n", stderr)
                exit(1)
            }
            guard hasActiveOperation(in: ["Digging through…", "/Users/example/file.heic"]),
                  hasActiveOperation(in: ["Scanning Macintosh HD"]),
                  !hasActiveOperation(in: ["Review All Files", "Remove 14.5 MB", "Start Over"]) else {
                fputs("Self-test failed: active operation classification\n", stderr)
                exit(1)
            }
            guard isMyClutterResultsPage(
                ["Start Over", "My Clutter", "You have 276 files to sort through.", "Review All Files"],
                moduleName: "My Clutter"
            ), !isMyClutterResultsPage(["Digging through…"], moduleName: "My Clutter"),
               estimatedStorageProgress(scanType: .myClutter, elapsed: 42.5) == 47,
               estimatedStorageProgress(scanType: .myClutter, elapsed: 200) == 95 else {
                fputs("Self-test failed: My Clutter progress state\n", stderr)
                exit(1)
            }
            guard hasActiveOperation(in: ["Visualizing your storage space...", "/Users/example"]),
                  isSpaceLensResultsPage(
                      ["Start Over", "Space Lens", "Macintosh HD", "1.1 TB of 2 TB used"],
                      moduleName: "Space Lens"
                  ),
                  isSpaceLensResultsPage(
                      ["Start Over", "Space Lens", "Too empty to visualize..."],
                      moduleName: "Space Lens"
                  ),
                  !isSpaceLensResultsPage(
                      ["Space Lens", "Visualizing your storage space..."],
                      moduleName: "Space Lens"
                  ) else {
                fputs("Self-test failed: Space Lens progress state\n", stderr)
                exit(1)
            }
            guard phaseAlignedProgress("cleanup") == 10,
                  phaseAlignedProgress("protection") == 35,
                  phaseAlignedProgress("clutter") == 88 else {
                fputs("Self-test failed: phase-aligned progress\n", stderr)
                exit(1)
            }
            let adaptiveSettings = PluginSettings(pollSeconds: 0.5)
            guard pollingInterval(for: .appClosed, settings: adaptiveSettings) == 15,
                  pollingInterval(for: .appIdle, settings: adaptiveSettings) == 2,
                  pollingInterval(for: .active, settings: adaptiveSettings) == 0.5 else {
                fputs("Self-test failed: adaptive polling intervals\n", stderr)
                exit(1)
            }

            let iconSettings = PluginSettings(compactPresentation: .moduleIcon)
            let iconPayload = activityPayload(
                commandType: "create",
                scanType: .cloudCleanup,
                progress: 42,
                settings: iconSettings,
                progressIsExact: true
            )
            guard let iconSurfaces = iconPayload["surfaces"] as? [String: Any],
                  let iconCompact = iconSurfaces["compactLiveActivity"] as? [String: Any],
                  let iconLeft = iconCompact["leftSlot"] as? [String: Any],
                  iconPayload["size"] as? String == "small",
                  iconLeft["source"] as? String == "inlineData",
                  iconLeft["mimeType"] as? String == "image/png",
                  let encoded = iconLeft["base64Data"] as? String,
                  !encoded.isEmpty else {
                fputs("Self-test failed: compact module icon payload\n", stderr)
                exit(1)
            }
            guard let exactRight = iconCompact["rightSlot"] as? [String: Any],
                  exactRight["value"] as? Double == 0.42 else {
                fputs("Self-test failed: exact progress payload\n", stderr)
                exit(1)
            }

            let indeterminatePayload = activityPayload(
                commandType: "update",
                scanType: .smartScan,
                progress: 37,
                settings: iconSettings
            )
            guard let indeterminateSurfaces = indeterminatePayload["surfaces"] as? [String: Any],
                  let indeterminateCompact = indeterminateSurfaces["compactLiveActivity"] as? [String: Any],
                  let indeterminateRight = indeterminateCompact["rightSlot"] as? [String: Any],
                  indeterminateRight["type"] as? String == "progress",
                  indeterminateRight["value"] == nil else {
                fputs("Self-test failed: indeterminate progress payload\n", stderr)
                exit(1)
            }

            let completePayload = activityPayload(
                commandType: "update",
                scanType: .systemJunk,
                progress: 100,
                settings: iconSettings,
                isReady: true
            )
            guard let completeSurfaces = completePayload["surfaces"] as? [String: Any],
                  let completeCompact = completeSurfaces["compactLiveActivity"] as? [String: Any],
                  let completeRight = completeCompact["rightSlot"] as? [String: Any],
                  completeRight["source"] as? String == "sfSymbol",
                  completeRight["systemImage"] as? String == "checkmark" else {
                fputs("Self-test failed: compact completion checkmark\n", stderr)
                exit(1)
            }

            let textSettings = PluginSettings(compactPresentation: .moduleName)
            let textPayload = activityPayload(
                commandType: "create",
                scanType: .spaceLens,
                progress: 42,
                settings: textSettings
            )
            guard let textSurfaces = textPayload["surfaces"] as? [String: Any],
                  let textCompact = textSurfaces["compactLiveActivity"] as? [String: Any],
                  let textLeft = textCompact["leftSlot"] as? [String: Any],
                  textPayload["size"] as? String == "large",
                  textLeft["text"] as? String == "Space Lens" else {
                fputs("Self-test failed: compact module name payload\n", stderr)
                exit(1)
            }

            print("Self-test passed (module mappings, payloads, adaptive polling)")
            exit(0)
        }

        if args.contains("--check") {
            print("Plugin: \(pluginName)")
            print("Runtime: Swift")
            print("Socket: \(ProcessInfo.processInfo.environment[socketEnvironmentKey] ?? "missing")")
            print("Settings: \(loadSettings())")
            print("Debug log: \(debugLogPath().path)")

            let running = NSWorkspace.shared.runningApplications
            let cmm = running.filter { app in
                if let id = app.bundleIdentifier, cmmBundleIDs.contains(id) { return true }
                if let name = app.localizedName, cmmProcessNames.contains(name) { return true }
                return false
            }

            if cmm.isEmpty {
                print("CleanMyMac: NOT running")
            } else {
                for app in cmm {
                    print("CleanMyMac: \(app.localizedName ?? "?") (bundle: \(app.bundleIdentifier ?? "?") pid: \(app.processIdentifier))")
                }
            }

            if let state = detectCleanMyMacState() {
                print("State: \(state.scanType.rawValue) at \(state.progress)%")
            } else {
                print("State: no scan detected")
            }
            exit(0)
        }

        if args.contains("--demo-json") {
            let payload = activityPayload(
                commandType: "create",
                scanType: .smartScan,
                progress: 42,
                settings: loadSettings(),
                progressIsExact: true
            )
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            exit(0)
        }

        guard let socketPath = ProcessInfo.processInfo.environment[socketEnvironmentKey],
              !socketPath.isEmpty else {
            fputs("\(pluginName): \(PluginError.socketPathMissing)\n", stderr)
            exit(64)
        }

        do {
            let client = JSONSocketClient(socketPath: socketPath)
            let plugin = CleanMyMacPlugin(client: client)
            runningPlugin = plugin
            try plugin.run()
        } catch {
            fputs("\(pluginName): \(error)\n", stderr)
            debugLog("fatal \(error)")
            exit(65)
        }
    }
}
