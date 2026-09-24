import SwiftUI
import Security

enum UploadDestination: String, CaseIterable, Identifiable {
    case localIP
    case ngrok

    var id: String { rawValue }
    var label: String { self == .localIP ? "研究室内IP" : "ngrok (外部HTTPS)" }
}

enum UploadSecretStore {
    private static let service = Bundle.main.bundleIdentifier ?? "iPhonePlantApp"
    private static let account = "ngrok-upload-api-key"

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func saveAPIKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

enum UploadFolderSettings {
    static let levelsKey = "ngrok_upload_folder_levels"

    static func load() -> [String] {
        if let saved = UserDefaults.standard.stringArray(forKey: levelsKey) {
            return Array(saved.prefix(2))
        }
        // 旧バージョンの設定を引き継ぐ
        let defaults = UserDefaults.standard
        let folder = defaults.string(forKey: "upload_folder") ?? "nakamura"
        let subfolder = defaults.string(forKey: "upload_subfolder") ?? "トマト動画"
        return [folder, subfolder]
    }

    static func save(_ levels: [String]) {
        UserDefaults.standard.set(Array(levels.prefix(2)), forKey: levelsKey)
    }
}

struct ServerSettingsSection: View {
    @Binding var serverIP: String
    @AppStorage("upload_destination") private var destinationRaw = UploadDestination.localIP.rawValue
    @AppStorage("ngrok_base_url") private var ngrokBaseURL = ""
    @State private var apiKey = ""
    @State private var folderLevels: [String] = []

    private var destination: Binding<UploadDestination> {
        Binding(
            get: { UploadDestination(rawValue: destinationRaw) ?? .localIP },
            set: { destinationRaw = $0.rawValue }
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("サーバー設定", systemImage: "network").foregroundColor(.cyan).font(.headline)
            Picker("送信方式", selection: destination) {
                ForEach(UploadDestination.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if destination.wrappedValue == .localIP {
                settingField("サーバーIP", text: $serverIP, keyboard: .numbersAndPunctuation)
                Text("送信先: http://IP:5000/upload")
                    .font(.caption2).foregroundColor(.gray)
            } else {
                settingField("https://….ngrok-free.dev", text: $ngrokBaseURL, keyboard: .URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("共有APIキー", text: $apiKey)
                    .foregroundColor(.white)
                    .padding(.vertical, 8).padding(.leading, 12)
                    .background(Color.white.opacity(0.1)).cornerRadius(10)
                    .onChange(of: apiKey) { UploadSecretStore.saveAPIKey($0) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("保存先フォルダ（0～2階層）")
                            .font(.caption).foregroundColor(.gray)
                        Spacer()
                        Button(action: addFolderLevel) {
                            Label("追加", systemImage: "plus.circle.fill")
                                .font(.caption.bold()).foregroundColor(.cyan)
                        }
                        .disabled(folderLevels.count >= 2)
                        .opacity(folderLevels.count >= 2 ? 0.4 : 1)
                    }

                    ForEach(Array(folderLevels.indices), id: \.self) { index in
                        HStack {
                            settingField(
                                index == 0 ? "1階層目（folder）" : "2階層目（subfolder）",
                                text: Binding(
                                    get: { folderLevels[index] },
                                    set: { folderLevels[index] = $0; UploadFolderSettings.save(folderLevels) }
                                )
                            )
                            Button(action: { removeFolderLevel(at: index) }) {
                                Image(systemName: "minus.circle.fill").foregroundColor(.red)
                            }
                        }
                    }

                    if folderLevels.isEmpty {
                        Text("入力欄なし：upload直下へ保存")
                            .font(.caption2).foregroundColor(.orange)
                    } else {
                        Text("保存先: upload/" + folderLevels.filter { !$0.isEmpty }.joined(separator: "/"))
                            .font(.caption2).foregroundColor(.green)
                    }
                }
                Text("APIキーはこのiPhoneのKeychainに保存されます。")
                    .font(.caption2).foregroundColor(.gray)
            }

            Button(action: { hideKeyboard() }) {
                Label("設定を保存", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.subheadline.bold())
            }
        }
        .onAppear {
            apiKey = UploadSecretStore.loadAPIKey()
            folderLevels = UploadFolderSettings.load()
        }
        .padding(.horizontal)
    }

    private func settingField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .foregroundColor(.white)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(Color.white.opacity(0.1)).cornerRadius(10)
    }

    private func addFolderLevel() {
        guard folderLevels.count < 2 else { return }
        folderLevels.append("")
        UploadFolderSettings.save(folderLevels)
    }

    private func removeFolderLevel(at index: Int) {
        guard folderLevels.indices.contains(index) else { return }
        folderLevels.remove(at: index)
        UploadFolderSettings.save(folderLevels)
    }
}
