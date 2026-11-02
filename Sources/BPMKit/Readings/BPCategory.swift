/// Blood-pressure category per the 2017 ACC/AHA guideline. Informational only.
public enum BPCategory: Int, CaseIterable, Comparable, Sendable {
    case normal, elevated, stage1, stage2, crisis

    public init(systolic: Int, diastolic: Int) {
        switch (systolic, diastolic) {
        case _ where systolic > 180 || diastolic > 120: self = .crisis
        case _ where systolic >= 140 || diastolic >= 90: self = .stage2
        case _ where systolic >= 130 || diastolic >= 80: self = .stage1
        case _ where systolic >= 120: self = .elevated
        default: self = .normal
        }
    }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .elevated: "Elevated"
        case .stage1: "Hypertension stage 1"
        case .stage2: "Hypertension stage 2"
        case .crisis: "Hypertensive crisis"
        }
    }

    public static func < (lhs: BPCategory, rhs: BPCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}
