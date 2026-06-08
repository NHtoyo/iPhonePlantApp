import SwiftUI

struct NamingRulesSection: View {
    @ObservedObject var uploadManager = UploadManager.shared
    @Binding var selectedRuleToEdit: NamingRule?
    @Binding var showNamingRuleEditor: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("フォルダ命名規則", systemImage: "character.cursor.ibeam").foregroundColor(.cyan).font(.headline)
                Spacer()
                Button(action: {
                    selectedRuleToEdit = nil
                    showNamingRuleEditor = true
                }) {
                    Image(systemName: "plus.circle.fill").foregroundColor(.green)
                }
            }
            
            ForEach(uploadManager.namingRules) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.name).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                        Text(rule.template).font(.system(size: 10)).foregroundColor(.gray)
                    }
                    Spacer()
                    if uploadManager.activeNamingRuleId == rule.id {
                        Image(systemName: "checkmark").foregroundColor(.green)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(8)
                .onTapGesture { uploadManager.activeNamingRuleId = rule.id }
                .onLongPressGesture {
                    selectedRuleToEdit = rule
                    showNamingRuleEditor = true
                }
            }
        }
        .padding(.horizontal)
    }
}
