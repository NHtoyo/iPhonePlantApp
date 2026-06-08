import SwiftUI

struct HistorySection: View {
    @ObservedObject var uploadManager = UploadManager.shared
    let serverIP: String
    @Binding var showDeleteAllConfirm: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("撮影履歴", systemImage: "clock.arrow.circlepath").foregroundColor(.cyan).font(.headline)
                Spacer()
                if !uploadManager.sessions.isEmpty {
                    Button(action: { showDeleteAllConfirm = true }) {
                        Text("すべて削除")
                            .font(.caption2).bold().foregroundColor(.red)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.red.opacity(0.1)).cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.3), lineWidth: 1))
                    }
                }
            }
            
            if uploadManager.sessions.isEmpty {
                Text("履歴がありません").foregroundColor(.gray).padding()
            } else {
                ForEach(uploadManager.sessions.reversed()) { session in
                    HistoryItemView(session: session, serverIP: serverIP)
                }
            }
        }
        .padding(.horizontal)
    }
}
