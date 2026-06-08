import SwiftUI

struct BoundingBoxOverlay: View {
    // Array of Rectangles representing the detected objects
    // The rects are in normalized coordinates (0.0 - 1.0)
    @Binding var boundingBoxes: [CGRect]
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0..<boundingBoxes.count, id: \.self) { index in
                    let box = boundingBoxes[index]
                    
                    // 1. 正規化座標 [0, 1] をデバイス画面のピクセル解像度にスケールマッピング
                    let screenBox = CGRect(
                        x: box.origin.x * geometry.size.width,
                        y: box.origin.y * geometry.size.height,
                        width: box.size.width * geometry.size.width,
                        height: box.size.height * geometry.size.height
                    )
                    
                    // 2. 2D バウンディングボックスの描画（未来的なネオンレッド枠のみ）
                    Rectangle()
                        .path(in: screenBox)
                        .stroke(Color.red, lineWidth: 2.5)
                    
                    // 4. ロックオン照準（どこを中心にしてるか一目でわかる赤い未来派ターゲットレティクル）
                    let centerX = screenBox.midX
                    let centerY = screenBox.midY
                    
                    // 中心ドット
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .position(x: centerX, y: centerY)
                    
                    // 点線のアウターリング
                    Circle()
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
                        .frame(width: 28, height: 28)
                        .position(x: centerX, y: centerY)
                    
                    // 十字照準線（中央を遮らないスマート仕様）
                    Path { path in
                        // 水平線
                        path.move(to: CGPoint(x: centerX - 22, y: centerY))
                        path.addLine(to: CGPoint(x: centerX - 8, y: centerY))
                        path.move(to: CGPoint(x: centerX + 8, y: centerY))
                        path.addLine(to: CGPoint(x: centerX + 22, y: centerY))
                        
                        // 垂直線
                        path.move(to: CGPoint(x: centerX, y: centerY - 22))
                        path.addLine(to: CGPoint(x: centerX, y: centerY - 8))
                        path.move(to: CGPoint(x: centerX, y: centerY + 8))
                        path.addLine(to: CGPoint(x: centerX, y: centerY + 22))
                    }
                    .stroke(Color.red, lineWidth: 1.5)
                }
            }
        }
    }
}
