import SwiftUI

struct ServerSettingsSection: View {
    @Binding var serverIP: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("サーバー設定", systemImage: "network").foregroundColor(.cyan).font(.headline)
            HStack {
                TextField("サーバーIP", text: $serverIP)
                    .keyboardType(.decimalPad)
                    .foregroundColor(.white)
                    .padding(.vertical, 8).padding(.leading, 12)
                Button(action: { hideKeyboard() }) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.title3).padding(.trailing, 10)
                }
            }
            .background(Color.white.opacity(0.1)).cornerRadius(10)
        }
        .padding(.horizontal)
    }
}
