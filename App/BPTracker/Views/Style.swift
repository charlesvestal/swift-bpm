import BPMKit
import SwiftUI

extension BPCategory {
    /// Green for the lowest category through yellow, orange and red to purple
    /// for the highest, whatever the number of categories in the guideline.
    var color: Color {
        let palette: [Color] = switch guideline {
        case .esh2023: [.green, .mint, .yellow, .orange, .red, .purple]
        case .accAha2017: [.green, .yellow, .orange, .red, .purple]
        }
        return palette[rank]
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
