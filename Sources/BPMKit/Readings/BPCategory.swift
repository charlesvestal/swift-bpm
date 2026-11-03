/// A blood-pressure classification scheme. Both are written for office
/// readings; home readings are usually judged against lower thresholds.
public enum BPGuideline: String, CaseIterable, Sendable, Identifiable {
    /// 2023 European Society of Hypertension, as used by European monitors such as Veroval.
    case esh2023
    /// 2017 American College of Cardiology / American Heart Association.
    case accAha2017

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .esh2023: "ESH 2023 (European)"
        case .accAha2017: "ACC/AHA 2017 (American)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .esh2023: "2023 ESH"
        case .accAha2017: "2017 ACC/AHA"
        }
    }

    var titles: [String] {
        switch self {
        case .esh2023:
            ["Optimal", "Normal", "High normal", "Grade 1 hypertension", "Grade 2 hypertension", "Grade 3 hypertension"]
        case .accAha2017:
            ["Normal", "Elevated", "Hypertension stage 1", "Hypertension stage 2", "Hypertensive crisis"]
        }
    }

    /// All categories, from lowest to highest.
    public var categories: [BPCategory] {
        titles.indices.map { BPCategory(guideline: self, rank: $0) }
    }

    public func category(systolic: Int, diastolic: Int) -> BPCategory {
        BPCategory(guideline: self, rank: rank(systolic: systolic, diastolic: diastolic))
    }

    private func rank(systolic s: Int, diastolic d: Int) -> Int {
        switch self {
        case .esh2023:
            // "and/or": the higher of the two ranks. Isolated systolic hypertension
            // (≥140 and <90) is graded by systolic, which this also does.
            let systolicRank = switch s {
            case ..<120: 0
            case 120..<130: 1
            case 130..<140: 2
            case 140..<160: 3
            case 160..<180: 4
            default: 5
            }
            let diastolicRank = switch d {
            case ..<80: 0
            case 80..<85: 1
            case 85..<90: 2
            case 90..<100: 3
            case 100..<110: 4
            default: 5
            }
            return max(systolicRank, diastolicRank)
        case .accAha2017:
            if s > 180 || d > 120 { return 4 }
            if s >= 140 || d >= 90 { return 3 }
            if s >= 130 || d >= 80 { return 2 }
            if s >= 120 { return 1 }
            return 0
        }
    }
}

/// A category within a guideline. Informational only.
public struct BPCategory: Hashable, Comparable, Sendable {
    public let guideline: BPGuideline
    /// 0 is the lowest category.
    public let rank: Int

    public var title: String { guideline.titles[rank] }

    /// 0 for the lowest category up to 1 for the highest, for colouring.
    public var severity: Double { Double(rank) / Double(guideline.titles.count - 1) }

    public static func < (lhs: BPCategory, rhs: BPCategory) -> Bool { lhs.rank < rhs.rank }
}
