import BPMKit
import Foundation

/// The language of exported reports (PDFs), independent of the app's own.
enum ReportLanguage: String, CaseIterable, Identifiable {
    case system, english, german

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Same as system"
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    var text: ReportText {
        switch self {
        case .english: ReportText(language: .english)
        case .german: ReportText(language: .german)
        case .system:
            Locale.preferredLanguages.first?.hasPrefix("de") == true ? ReportText(language: .german) : ReportText(language: .english)
        }
    }
}

/// Wording, names and date formats for one report language. Phrases are
/// written in place as `text("English", "Deutsch")` so the pair stays together.
struct ReportText {
    enum Language { case english, german }

    let language: Language

    static let english = ReportText(language: .english)

    /// The language chosen in Settings.
    static var current: ReportText {
        (UserDefaults.standard.string(forKey: AppSettings.reportLanguage).flatMap(ReportLanguage.init(rawValue:)) ?? .system).text
    }

    var isGerman: Bool { language == .german }

    /// German formats for German; otherwise the user's own region if it is English, else US English.
    var locale: Locale {
        if isGerman { return Locale(identifier: "de_DE") }
        return Locale.current.language.languageCode == .english ? Locale.current : Locale(identifier: "en_US")
    }

    func callAsFunction(_ english: String, _ german: String) -> String { isGerman ? german : english }

    /// "42%" in English, "42 %" in German.
    func percent(_ fraction: Double) -> String {
        let value = Int((fraction * 100).rounded())
        return isGerman ? "\(value) %" : "\(value)%"
    }

    // MARK: Names

    func category(_ category: BPCategory) -> String {
        guard isGerman else { return category.title }
        switch category.guideline {
        case .esh2023:
            return ["Optimal", "Normal", "Hoch normal", "Hypertonie Grad 1", "Hypertonie Grad 2", "Hypertonie Grad 3"][category.rank]
        case .accAha2017:
            return ["Normal", "Erhöht", "Hypertonie Stadium 1", "Hypertonie Stadium 2", "Hypertensive Krise"][category.rank]
        }
    }

    func timeOfDay(_ part: TimeOfDay) -> String {
        guard isGerman else { return part.title }
        switch part {
        case .morning: return "Morgens"
        case .afternoon: return "Nachmittags"
        case .evening: return "Abends"
        case .night: return "Nachts"
        }
    }

    func session(_ session: HomeSession) -> String {
        guard isGerman else { return session.title }
        return session == .morning ? "Morgens" : "Abends"
    }

    func guideline(_ guideline: BPGuideline) -> String {
        guard isGerman else { return guideline.shortTitle }
        return guideline == .esh2023 ? "ESH 2023" : "ACC/AHA 2017"
    }

    var seriesNames: (systolic: String, diastolic: String, pulse: String) {
        isGerman ? ("Systolisch", "Diastolisch", "Puls") : ("Systolic", "Diastolic", "Pulse")
    }

    // MARK: Dates

    func date(_ date: Date, _ dateStyle: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: time, locale: locale))
    }

    /// "Mon 3" / "Mo., 3."
    func weekdayAndDay(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated).day())
    }

    func periodTitle(_ period: Period) -> String {
        switch period.kind {
        case .all: return self("All readings", "Alle Messungen")
        case .week:
            let start = period.interval()?.start ?? period.anchor
            return self("Week of", "Woche ab") + " " + date(start, .abbreviated)
        case .month: return period.anchor.formatted(Date.FormatStyle(locale: locale).month(.wide).year())
        case .year: return period.anchor.formatted(Date.FormatStyle(locale: locale).year())
        case .last365: return self("Last 12 months", "Letzte 12 Monate")
        case .last7, .last30, .last90:
            let days = period.kind.days ?? 0
            return self("Last \(days) days", "Letzte \(days) Tage")
        }
    }
}
