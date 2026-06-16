import SwiftUI

struct SideMenuView: View {
    @Binding var isPresented: Bool
    @Binding var serverIP: String
    @Binding var showDeleteAllConfirm: Bool
    
    @ObservedObject var uploadManager = UploadManager.shared
    @State private var showNamingRuleEditor = false
    @State private var selectedRuleToEdit: NamingRule? = nil
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                // ヘッダー
                HStack {
                    Text("メニュー").font(.title2).fontWeight(.bold).foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        hideKeyboard()
                        withAnimation { isPresented = false }
                    }) {
                        Image(systemName: "xmark").foregroundColor(.white)
                    }
                }
                .padding(.top, 60).padding(.horizontal)
                
                Divider().background(Color.white.opacity(0.3))
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        ServerSettingsSection(serverIP: $serverIP)
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        NamingRulesSection(
                            selectedRuleToEdit: $selectedRuleToEdit,
                            showNamingRuleEditor: $showNamingRuleEditor
                        )
                        
                        Divider().background(Color.white.opacity(0.1))
                        
                        HistorySection(
                            serverIP: serverIP,
                            showDeleteAllConfirm: $showDeleteAllConfirm
                        )
                    }
                }
                
                Spacer()
                Text("Version 3.4.3").font(.caption).foregroundColor(.gray).padding()
            }
            .frame(width: 280)
            .background(Color(white: 0.12))
            .edgesIgnoringSafeArea(.all)
            .alert("全履歴を削除", isPresented: $showDeleteAllConfirm) {
                Button("すべて削除", role: .destructive) { UploadManager.shared.deleteAllSessions() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("撮影したすべてのデータ（画像・深度マップ等）をiPhoneから物理的に削除します。よろしいですか？")
            }
            Spacer()
        }
        .sheet(isPresented: $showNamingRuleEditor) {
            NamingRuleEditorView(ruleToEdit: selectedRuleToEdit)
        }
    }
}

// MARK: - 命名規則エディタ

struct NamingRuleEditorView: View {
    @Environment(\.presentationMode) var presentationMode
    @ObservedObject var uploadManager = UploadManager.shared
    
    @State private var ruleName: String = ""
    @State private var template: String = ""
    var ruleToEdit: NamingRule?
    
    let placeholders = [
        ("年", "[YYYY]"), ("月", "[MM]"), ("日", "[DD]"),
        ("時", "[HH]"), ("分", "[mm]"), ("秒", "[ss]"),
        ("日付一括", "[Date]"), ("時刻一括", "[Time]"), ("連番", "[Count]")
    ]
    
    init(ruleToEdit: NamingRule? = nil) {
        self.ruleToEdit = ruleToEdit
        _ruleName = State(initialValue: ruleToEdit?.name ?? "")
        _template = State(initialValue: ruleToEdit?.template ?? "")
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("表示名 (管理用の名前)").font(.caption).foregroundColor(.cyan)
                        TextField("例: トマト温室_A", text: $ruleName)
                            .padding().background(Color.white.opacity(0.1)).cornerRadius(10)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("テンプレート (実際のフォルダ名)").font(.caption).foregroundColor(.cyan)
                        TextField("例: Tomato_[Date]_[Count]", text: $template)
                            .padding().background(Color.white.opacity(0.1)).cornerRadius(10)
                            .font(.system(.body, design: .monospaced))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("プレビュー:").font(.caption).foregroundColor(.gray)
                            Text(previewName)
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(8)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("変数の雛形 (タップで挿入)").font(.caption).foregroundColor(.gray)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 85))], spacing: 10) {
                            ForEach(placeholders, id: \.1) { label, tag in
                                Button(action: { template += tag }) {
                                    Text(label).font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                                        .background(Color.blue.opacity(0.2)).foregroundColor(.blue).cornerRadius(8)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.5), lineWidth: 1))
                                }
                            }
                        }
                    }
                    
                    if ruleToEdit != nil {
                        Button(role: .destructive, action: {
                            if let id = ruleToEdit?.id {
                                uploadManager.removeNamingRule(id: id)
                                presentationMode.wrappedValue.dismiss()
                            }
                        }) {
                            HStack { Image(systemName: "trash"); Text("この規則を削除") }
                            .frame(maxWidth: .infinity).padding().background(Color.red.opacity(0.2)).foregroundColor(.red)
                            .cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.5), lineWidth: 1))
                        }
                    }
                    Spacer()
                }
                .padding()
            }
            .background(Color(white: 0.1).edgesIgnoringSafeArea(.all))
            .navigationTitle(ruleToEdit == nil ? "新しい規則" : "規則の編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("キャンセル") { presentationMode.wrappedValue.dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("保存") { saveRule() }.disabled(ruleName.isEmpty || template.isEmpty) }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var previewName: String {
        if template.isEmpty { return "(未入力)" }
        var p = template
        p = p.replacingOccurrences(of: "[YYYY]", with: "2024")
        p = p.replacingOccurrences(of: "[MM]", with: "05")
        p = p.replacingOccurrences(of: "[DD]", with: "13")
        p = p.replacingOccurrences(of: "[HH]", with: "10")
        p = p.replacingOccurrences(of: "[mm]", with: "00")
        p = p.replacingOccurrences(of: "[ss]", with: "00")
        p = p.replacingOccurrences(of: "[Date]", with: "2024-05-13")
        p = p.replacingOccurrences(of: "[Time]", with: "10-00-00")
        p = p.replacingOccurrences(of: "[Count]", with: "1")
        return p
    }
    
    private func saveRule() {
        if var rule = ruleToEdit {
            if let idx = uploadManager.namingRules.firstIndex(where: { $0.id == rule.id }) {
                rule.name = ruleName; rule.template = template; uploadManager.namingRules[idx] = rule
            }
        } else {
            let newRule = NamingRule(name: ruleName, template: template)
            uploadManager.namingRules.append(newRule)
        }
        presentationMode.wrappedValue.dismiss()
    }
}
