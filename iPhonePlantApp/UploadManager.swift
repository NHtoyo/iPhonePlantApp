import Foundation
import Combine
import SwiftUI

// MARK: - Upload Status

enum UploadStatus: String, Codable {
    case savedLocal  // 録画完了・未送信
    case uploading   // 送信中（ローカルは必ず保持）
    case uploaded    // 送信成功（ローカルも保持）
    case failed      // 送信失敗（ローカルは安全）
}

// MARK: - Session Record

struct SessionRecord: Codable, Identifiable {
    var id: String          // セッション名（フォルダ名）
    var localPath: String   // セッション名（フォルダ名） - コンテナパスが変動するため相対パスで保持
    var status: UploadStatus
    var lastAttempt: Date?
    var errorMessage: String?

    // ローカルフォルダへのフルパス
    var localURL: URL {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docsDir.appendingPathComponent(localPath)
    }
}

// MARK: - Naming Rule

struct NamingRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String        // ルールの表示名（例：場所＋日付）
    var template: String    // テンプレート（例：Tomato_[YYYYMMDD]_[Count]）
    
    static let defaultRule = NamingRule(name: "デフォルト", template: "nerf_dataset_[Date]_[Time]")
}

// MARK: - Upload Manager

class UploadManager: ObservableObject {
    static let shared = UploadManager()

    @Published var sessions: [SessionRecord] = []
    
    // 命名規則の管理
    @Published var namingRules: [NamingRule] = [] {
        didSet { saveNamingRules() }
    }
    @Published var activeNamingRuleId: UUID = UUID() {
        didSet { UserDefaults.standard.set(activeNamingRuleId.uuidString, forKey: "active_naming_rule_id") }
    }

    // 自動送信のON/OFFフラグ
    @Published var autoUploadEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoUploadEnabled, forKey: "auto_upload_enabled")
        }
    }

    private let userDefaultsKey = "upload_sessions"
    private let namingRulesKey = "naming_rules"
    private let uploadQueue = DispatchQueue(label: "com.plantapp.uploadqueue", qos: .utility)

    /// タイムアウト（秒）
    private let uploadTimeoutSeconds: TimeInterval = 60

    /// キャンセル用タスク参照
    private var currentTask: URLSessionDataTask?
    private var timeoutWorkItem: DispatchWorkItem?

    private init() { 
        self.autoUploadEnabled = UserDefaults.standard.object(forKey: "auto_upload_enabled") as? Bool ?? true
        load()
        loadNamingRules()
        print("DEBUG [UploadManager]: Initialized")
    }

    // MARK: - 永続化

    private func loadNamingRules() {
        if let data = UserDefaults.standard.data(forKey: namingRulesKey),
           let decoded = try? JSONDecoder().decode([NamingRule].self, from: data) {
            self.namingRules = decoded
        } else {
            self.namingRules = [NamingRule.defaultRule]
        }
        
        if let idString = UserDefaults.standard.string(forKey: "active_naming_rule_id"),
           let uuid = UUID(uuidString: idString) {
            self.activeNamingRuleId = uuid
        } else {
            self.activeNamingRuleId = self.namingRules.first?.id ?? UUID()
        }
    }

    private func saveNamingRules() {
        if let data = try? JSONEncoder().encode(namingRules) {
            UserDefaults.standard.set(data, forKey: namingRulesKey)
        }
    }

    // MARK: - フォルダ名生成

    func generateFolderName() -> String {
        guard let rule = namingRules.first(where: { $0.id == activeNamingRuleId }) else {
            return "nerf_dataset_\(Date().formattedString())"
        }
        
        let template = rule.template
        let date = Date()
        let calendar = Calendar.current
        
        var name = template
        name = name.replacingOccurrences(of: "[YYYY]", with: String(format: "%04d", calendar.component(.year, from: date)))
        name = name.replacingOccurrences(of: "[MM]", with: String(format: "%02d", calendar.component(.month, from: date)))
        name = name.replacingOccurrences(of: "[DD]", with: String(format: "%02d", calendar.component(.day, from: date)))
        name = name.replacingOccurrences(of: "[HH]", with: String(format: "%02d", calendar.component(.hour, from: date)))
        name = name.replacingOccurrences(of: "[mm]", with: String(format: "%02d", calendar.component(.minute, from: date)))
        name = name.replacingOccurrences(of: "[ss]", with: String(format: "%02d", calendar.component(.second, from: date)))
        name = name.replacingOccurrences(of: "[Date]", with: date.formattedDateOnly())
        name = name.replacingOccurrences(of: "[Time]", with: date.formattedTimeOnly())
        
        // [Count] の処理
        if name.contains("[Count]") {
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            var counter = 1
            var finalName = ""
            
            repeat {
                finalName = name.replacingOccurrences(of: "[Count]", with: "\(counter)")
                counter += 1
            } while FileManager.default.fileExists(atPath: docsDir.appendingPathComponent(finalName).path)
            
            return finalName
        }
        
        return name
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data) else { return }
        DispatchQueue.main.async { 
            var loadedSessions = decoded
            for i in 0..<loadedSessions.count {
                if loadedSessions[i].status == .uploading {
                    loadedSessions[i].status = .failed
                    loadedSessions[i].errorMessage = "中断されました"
                }
            }
            self.sessions = loadedSessions 
            self.save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }

    // MARK: - セッション管理

    /// セッションを削除（物理ファイルも削除）
    func deleteSession(id: String) {
        print("DEBUG [UploadManager]: Deleting session: \(id)")
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            let session = sessions[idx]
            do {
                try FileManager.default.removeItem(at: session.localURL)
            } catch {
                print("DEBUG [UploadManager]: Failed to delete local file: \(error.localizedDescription)")
            }
            sessions.remove(at: idx)
            save()
        }
    }
    
    /// 全セッションを削除（物理ファイルも削除）
    func deleteAllSessions() {
        print("DEBUG [UploadManager]: Deleting ALL sessions")
        for session in sessions {
            do {
                try FileManager.default.removeItem(at: session.localURL)
            } catch {
                print("DEBUG [UploadManager]: Failed to delete [\(session.id)]: \(error.localizedDescription)")
            }
        }
        sessions.removeAll()
        save()
    }

    /// セッション名を変更（フォルダ名も変更）
    func renameSession(id: String, newName: String, serverIP: String) {
        print("DEBUG [UploadManager]: Renaming session: \(id) -> \(newName)")
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldURL = docsDir.appendingPathComponent(id)
        let newURL = docsDir.appendingPathComponent(newName)
        
        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            DispatchQueue.main.async {
                if let idx = self.sessions.firstIndex(where: { $0.id == id }) {
                    self.sessions[idx].id = newName
                    self.sessions[idx].localPath = newName
                    self.save()
                }
            }
            syncRenameToServer(oldName: id, newName: newName, serverIP: serverIP)
        } catch {
            print("DEBUG [UploadManager]: Rename failed: \(error.localizedDescription)")
        }
    }

    func register(sessionURL: URL) {
        let sessionName = sessionURL.lastPathComponent
        let record = SessionRecord(
            id: sessionName,
            localPath: sessionName,
            status: .savedLocal,
            lastAttempt: nil,
            errorMessage: nil
        )
        print("DEBUG [UploadManager]: Registering session: \(record.id)")
        
        if Thread.isMainThread {
            self.addRecord(record)
        } else {
            DispatchQueue.main.sync {
                self.addRecord(record)
            }
        }
    }

    private func addRecord(_ record: SessionRecord) {
        if !self.sessions.contains(where: { $0.id == record.id }) {
            self.sessions.append(record)
            self.save()
        }
    }

    func removeNamingRule(id: UUID) {
        DispatchQueue.main.async {
            self.namingRules.removeAll(where: { $0.id == id })
            if self.activeNamingRuleId == id {
                self.activeNamingRuleId = self.namingRules.first?.id ?? UUID()
            }
            self.saveNamingRules()
        }
    }

    private func syncRenameToServer(oldName: String, newName: String, serverIP: String) {
        guard !serverIP.isEmpty, let url = URL(string: "http://\(serverIP):5000/rename") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["old_name": oldName, "new_name": newName]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - 状態更新

    private func updateStatus(id: String, status: UploadStatus, errorMessage: String? = nil) {
        DispatchQueue.main.async {
            if let idx = self.sessions.firstIndex(where: { $0.id == id }) {
                self.sessions[idx].status = status
                self.sessions[idx].lastAttempt = Date()
                self.sessions[idx].errorMessage = errorMessage
                self.save()
            }
        }
    }

    // MARK: - 未送信件数

    var pendingCount: Int {
        sessions.filter { $0.status == .savedLocal || $0.status == .failed }.count
    }

    // MARK: - 強制キャンセル

    func cancelCurrentUpload() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - TAR作成

    private func createTAR(sessionURL: URL, archiveURL: URL) throws {
        try? FileManager.default.removeItem(at: archiveURL)
        guard let tarStream = OutputStream(url: archiveURL, append: false) else {
            throw NSError(domain: "Upload", code: 1, userInfo: [NSLocalizedDescriptionKey: "OutputStream creation failed"])
        }
        tarStream.open()
        defer { tarStream.close() }
        let files = try FileManager.default.subpathsOfDirectory(atPath: sessionURL.path)
        for (index, file) in files.enumerated() {
            autoreleasepool {
                let fileURL = sessionURL.appendingPathComponent(file)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { return }
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                      let size = attributes[.size] as? Int64 else { return }
                
                var header = [UInt8](repeating: 0, count: 512)
                let nameBytes = Array(file.utf8.prefix(99))
                for (i, b) in nameBytes.enumerated() { header[i] = b }
                let sizeOctal = String(format: "%011o\0", size)
                for (i, b) in Array(sizeOctal.utf8).enumerated() { header[124 + i] = b }
                header[156] = UInt8(ascii: "0")
                for (i, _) in [UInt8](repeating: 0x20, count: 8).enumerated() { header[148 + i] = 0x20 }
                let checksum = header.reduce(0) { $0 + Int($1) }
                let checksumStr = String(format: "%06o\0 ", checksum)
                for (i, b) in Array(checksumStr.utf8).enumerated() { header[148 + i] = b }
                tarStream.write(header, maxLength: 512)
                
                if let inputStream = InputStream(url: fileURL) {
                    inputStream.open()
                    let bufferSize = 32768
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                    defer { buffer.deallocate() }
                    while inputStream.hasBytesAvailable {
                        let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
                        if bytesRead < 0 { break }
                        if bytesRead > 0 { tarStream.write(buffer, maxLength: bytesRead) }
                    }
                    inputStream.close()
                }
                
                let padding = (512 - (Int(size) % 512)) % 512
                if padding > 0 {
                    let padBytes = [UInt8](repeating: 0, count: padding)
                    tarStream.write(padBytes, maxLength: padding)
                }
            }
        }
        let endBytes = [UInt8](repeating: 0, count: 1024)
        tarStream.write(endBytes, maxLength: 1024)
    }

    // MARK: - アップロード

    func upload(sessionId: String, serverIP: String, completion: @escaping (Bool, String) -> Void) {
        guard let record = sessions.first(where: { $0.id == sessionId }) else {
            completion(false, "Session not found")
            return
        }
        let sessionURL = record.localURL
        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            updateStatus(id: sessionId, status: .failed, errorMessage: "Data not found")
            completion(false, "データなし")
            return
        }
        updateStatus(id: sessionId, status: .uploading)
        timeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.currentTask?.cancel()
            self.currentTask = nil
            self.updateStatus(id: sessionId, status: .failed, errorMessage: "Timeout")
            DispatchQueue.main.async { completion(false, "タイムアウト") }
        }
        self.timeoutWorkItem = timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + self.uploadTimeoutSeconds, execute: timeout)
        
        uploadQueue.async { [weak self] in
            guard let self = self else { return }
            let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(sessionId).tar")
            let multipartURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(sessionId)_multipart.tmp")
            
            do {
                try self.createTAR(sessionURL: sessionURL, archiveURL: archiveURL)
                guard let url = URL(string: "http://\(serverIP):5000/upload") else {
                    self.timeoutWorkItem?.cancel()
                    self.updateStatus(id: sessionId, status: .failed, errorMessage: "Invalid URL")
                    DispatchQueue.main.async { completion(false, "URL不正") }
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                let boundary = "Boundary-\(UUID().uuidString)"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                
                // --- ストリーミング用に一時ファイルにマルチパートボディを構築 ---
                try? FileManager.default.removeItem(at: multipartURL)
                guard let outStream = OutputStream(url: multipartURL, append: false) else { throw NSError(domain: "", code: 2, userInfo: nil) }
                outStream.open()
                
                let headerStr = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(archiveURL.lastPathComponent)\"\r\nContent-Type: application/x-tar\r\n\r\n"
                if let headerData = headerStr.data(using: .utf8) {
                    headerData.withUnsafeBytes { ptr in
                        outStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: headerData.count)
                    }
                }
                
                if let inStream = InputStream(url: archiveURL) {
                    inStream.open()
                    let bufferSize = 32768
                    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                    defer { buffer.deallocate() }
                    while inStream.hasBytesAvailable {
                        let bytesRead = inStream.read(buffer, maxLength: bufferSize)
                        if bytesRead < 0 { break }
                        if bytesRead > 0 { outStream.write(buffer, maxLength: bytesRead) }
                    }
                    inStream.close()
                }
                
                let footerStr = "\r\n--\(boundary)--\r\n"
                if let footerData = footerStr.data(using: .utf8) {
                    footerData.withUnsafeBytes { ptr in
                        outStream.write(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: footerData.count)
                    }
                }
                outStream.close()
                // ----------------------------------------------------
                
                let task = URLSession.shared.uploadTask(with: request, fromFile: multipartURL) { [weak self] data, response, error in
                    guard let self = self else { return }
                    self.timeoutWorkItem?.cancel()
                    self.currentTask = nil
                    try? FileManager.default.removeItem(at: archiveURL)
                    try? FileManager.default.removeItem(at: multipartURL)
                    
                    if let error = error {
                        let nsError = error as NSError
                        var readableMsg = "通信エラー"
                        if nsError.domain == NSURLErrorDomain {
                            switch nsError.code {
                            case NSURLErrorNotConnectedToInternet:
                                readableMsg = "ネット未接続"
                            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                                readableMsg = "サーバー接続不可(IP/FW確認)"
                            case NSURLErrorTimedOut:
                                readableMsg = "タイムアウト"
                            case NSURLErrorNetworkConnectionLost:
                                readableMsg = "通信切断"
                            default:
                                readableMsg = "通信エラー(\(nsError.code))"
                            }
                        } else {
                            readableMsg = error.localizedDescription
                        }
                        self.updateStatus(id: sessionId, status: .failed, errorMessage: readableMsg)
                        DispatchQueue.main.async { completion(false, readableMsg) }
                        return
                    }
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        self.updateStatus(id: sessionId, status: .uploaded)
                        DispatchQueue.main.async { completion(true, "✅ 成功") }
                    } else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        var msg = "サーバーエラー (\(code))"
                        if code == 413 { msg = "データサイズ超過 (413)" }
                        else if code == 500 { msg = "サーバー内部エラー (500)" }
                        
                        self.updateStatus(id: sessionId, status: .failed, errorMessage: msg)
                        DispatchQueue.main.async { completion(false, msg) }
                    }
                }
                self.currentTask = task
                task.resume()
            } catch {
                self.timeoutWorkItem?.cancel()
                self.updateStatus(id: sessionId, status: .failed, errorMessage: error.localizedDescription)
                DispatchQueue.main.async { completion(false, "作成失敗") }
                try? FileManager.default.removeItem(at: archiveURL)
                try? FileManager.default.removeItem(at: multipartURL)
            }
        }
    }

    func retryAll(serverIP: String, progressCallback: @escaping (Int, Int, String) -> Void) {
        let pending = sessions.filter { $0.status == .savedLocal || $0.status == .failed }
        let total = pending.count
        
        if pending.isEmpty {
            DispatchQueue.main.async { progressCallback(0, 0, "未送信なし") }
            return
        }
        
        var completed = 0
        
        func uploadNext(_ index: Int) {
            guard index < total else {
                let statusMsg = (completed == total) ? "完了" : "\(total-completed)件失敗"
                DispatchQueue.main.async { progressCallback(completed, total, statusMsg) }
                return
            }
            
            let session = pending[index]
            print("DEBUG [UploadManager]: Starting upload (\(index+1)/\(total)): \(session.id)")
            DispatchQueue.main.async { progressCallback(completed, total, "(\(index+1)/\(total)) \(session.id) 送信中...") }
            
            upload(sessionId: session.id, serverIP: serverIP) { success, errorMsg in
                if success {
                    completed += 1
                    print("DEBUG [UploadManager]: Upload SUCCESS: \(session.id)")
                } else {
                    print("DEBUG [UploadManager]: Upload FAILED: \(session.id) - \(errorMsg ?? "Unknown error")")
                    // 1件失敗しても次へ進むが、進捗としてエラーを通知
                    DispatchQueue.main.async { progressCallback(completed, total, "❌ エラー: \(session.id)") }
                }
                uploadNext(index + 1)
            }
        }
        
        uploadNext(0)
    }
}

extension URL {
    var fileSizeDescription: String {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64 else { return "0" }
        return size > 1_048_576 ? "\(size / 1_048_576)MB" : "\(size / 1024)KB"
    }
}

extension Date {
    func formattedString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: self)
    }
    func formattedDateOnly() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
    func formattedTimeOnly() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        return formatter.string(from: self)
    }
}
