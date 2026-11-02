import BPMKit
import SwiftUI

extension BPCategory {
    var color: Color {
        switch self {
        case .normal: .green
        case .elevated: .yellow
        case .stage1: .orange
        case .stage2: .red
        case .crisis: .purple
        }
    }
}

extension Reading {
    var pressureText: String { "\(systolic)/\(diastolic)" }
}

struct CategoryBadge: View {
    let category: BPCategory

    var body: some View {
        Label(category.title, systemImage: "circle.fill")
            .labelStyle(.titleAndIcon)
            .symbolRenderingMode(.palette)
            .foregroundStyle(category.color, .primary)
            .imageScale(.small)
    }
}
