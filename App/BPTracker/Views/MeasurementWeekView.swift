import BPMKit
import SwiftData
import SwiftUI

/// Home-monitoring weeks for one profile: start one, follow its progress,
/// read the result and export it.
struct MeasurementWeekView: View {
    let profile: Profile

    @Environment(\.modelContext) private var context
    @Query(sort: \MeasurementWeek.start, order: .reverse) private var allWeeks: [MeasurementWeek]
    @AppStorage(AppSettings.guideline) private var guideline = BPGuideline.esh2023
    @State private var selectedID: UUID?
    @State private var starting = false
    @State private var confirmDelete = false
    @State private var export: ExportFile?

    private var weeks: [MeasurementWeek] { allWeeks.filter { $0.profileID == profile.uuid } }
    private var selected: MeasurementWeek? { weeks.first { $0.uuid == selectedID } ?? weeks.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let week = selected {
                    header(week)
                    let result = HomeMonitoringResult(points: profile.readings.filter { !$0.hidden }.map(\.point),
                                                      plan: week.plan, guideline: guideline)
                    WeekResultTiles(result: result, finished: week.isFinished())
                    GroupBox("Sessions") {
                        WeekGrid(result: result).padding(6)
                    }
                    protocolNote
                } else {
                    intro
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $starting) {
            StartWeekSheet(profile: profile) { selectedID = $0.uuid }
        }
        .confirmationDialog("Delete this measurement week?", isPresented: $confirmDelete) {
            Button("Delete Week", role: .destructive) {
                if let week = selected {
                    WeekReminders.cancel(week)
                    context.delete(week)
                    try? context.save()
                    selectedID = nil
                }
            }
        } message: {
            Text("The readings stay; only the week and its reminders are removed.")
        }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: export, contentType: .pdf, defaultFilename: export?.filename) { _ in export = nil }
        .onAppear { WeekReminders.withdrawCompleted(in: context) }
        .onChange(of: profile.readings.count) { WeekReminders.withdrawCompleted(in: context) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measurement week").font(.title2.bold())
            Text("Doctors often ask for a week of home readings. For seven days, take two readings a minute apart each morning and each evening, sitting quietly for five minutes first. The first day is practice and left out; the rest are averaged.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The app reminds you at your chosen times, tracks each session as readings arrive from your monitor or by hand, and makes a report for your clinician.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start a Measurement Week…") { starting = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func header(_ week: MeasurementWeek) -> some View {
        HStack {
            Picker("Week", selection: Binding(get: { selected?.uuid }, set: { selectedID = $0 })) {
                ForEach(weeks) { w in
                    Text(title(w)).tag(Optional(w.uuid))
                }
            }
            .labelsHidden()
            .fixedSize()
            if week.remindersEnabled && !week.isFinished() {
                Label("Reminders at \(time(week.morningMinutes)) and \(time(week.eveningMinutes))", systemImage: "bell")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("New Week…") { starting = true }
            Button("PDF Report…") {
                let data = PDFReport.renderWeek(profileName: profile.name, week: week, readings: profile.readings,
                                                guideline: guideline)
                export = ExportFile(data: data, contentType: .pdf,
                                    filename: "Blood Pressure Week – \(profile.name) – \(week.start.formatted(.iso8601.year().month().day())).pdf")
            }
            Button("Delete…", role: .destructive) { confirmDelete = true }
        }
    }

    private var protocolNote: some View {
        Text("Average of days 2–\(selected?.days ?? 7) (day 1 is practice), as recommended by the European Society of Hypertension. At least 12 readings over 3 days are needed. A home average of 135/85 or more is considered raised. This is not a diagnosis.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func title(_ week: MeasurementWeek) -> String {
        let range = "\(week.start.formatted(.dateTime.month().day())) – \(week.plan.end().addingTimeInterval(-1).formatted(.dateTime.month().day().year()))"
        return week.isActive() ? "\(range) (in progress)" : week.isFinished() ? range : "\(range) (upcoming)"
    }

    private func time(_ minutes: Int) -> String {
        Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: Date()))!
            .formatted(date: .omitted, time: .shortened)
    }
}

private struct WeekResultTiles: View {
    let result: HomeMonitoringResult
    let finished: Bool

    var body: some View {
        HStack(spacing: 12) {
            tile("Home average") {
                Text(pressure(result.summary)).font(.title.bold()).monospacedDigit()
                Text(assessment).font(.caption).foregroundStyle(assessmentColor)
            }
            tile("Morning") {
                Text(pressure(result.morning)).font(.title2.bold()).monospacedDigit()
                Text("\(result.morning.count) readings").font(.caption).foregroundStyle(.secondary)
            }
            tile("Evening") {
                Text(pressure(result.evening)).font(.title2.bold()).monospacedDigit()
                Text("\(result.evening.count) readings").font(.caption).foregroundStyle(.secondary)
            }
            tile("Progress") {
                Text("\(result.completedSessions) of \(result.expectedSessions)").font(.title2.bold()).monospacedDigit()
                Text("sessions · \(result.included.count) readings counted").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var assessment: String {
        guard let raised = result.isRaised else { return "No readings yet" }
        if !result.meetsMinimum {
            return "Not enough yet (\(result.included.count) of \(HomeMonitoringPlan.minimumReadings) readings)"
        }
        return raised ? "At or above 135/85" : "Below 135/85"
    }

    private var assessmentColor: Color {
        guard result.meetsMinimum, let raised = result.isRaised else { return .secondary }
        return raised ? .orange : .green
    }

    private func pressure(_ s: BPSummary) -> String {
        guard let sys = s.systolic, let dia = s.diastolic else { return "–" }
        return "\(Int(sys.mean.rounded()))/\(Int(dia.mean.rounded()))"
    }

    private func tile(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Days across, morning and evening down; each cell shows the session's readings.
struct WeekGrid: View {
    let result: HomeMonitoringResult
    var compact = false
    var now = Date()

    var body: some View {
        Grid(alignment: .center, horizontalSpacing: compact ? 6 : 10, verticalSpacing: compact ? 4 : 8) {
            GridRow {
                Text("")
                ForEach(result.days, id: \.index) { day in
                    VStack(spacing: 0) {
                        Text("Day \(day.index + 1)").fontWeight(.semibold)
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated).day())).foregroundStyle(.secondary)
                        if day.excluded { Text("practice").foregroundStyle(.secondary).italic() }
                    }
                    .font(compact ? .system(size: 8) : .caption)
                }
            }
            ForEach(HomeSession.allCases, id: \.self) { session in
                GridRow {
                    Text(session.title).font(compact ? .system(size: 8, weight: .semibold) : .callout.weight(.semibold))
                        .gridColumnAlignment(.leading)
                    ForEach(result.days, id: \.index) { day in
                        cell(day, session)
                    }
                }
            }
        }
    }

    private func cell(_ day: HomeMonitoringResult.Day, _ session: HomeSession) -> some View {
        let readings = day.readings(session)
        let complete = day.isComplete(session)
        let past = sessionEnd(day, session) < now
        let symbol = complete ? "checkmark.circle.fill" : readings.isEmpty ? (past ? "xmark.circle" : "circle") : "circle.lefthalf.filled"
        let color: Color = complete ? .green : readings.isEmpty ? (past ? .red : .secondary) : .orange
        return VStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(color)
            if let avg = average(readings) {
                Text(avg).monospacedDigit()
                Text("\(readings.count)×").foregroundStyle(.secondary)
            } else {
                Text(past ? "missed" : "–").foregroundStyle(.secondary)
            }
        }
        .font(compact ? .system(size: 8) : .caption)
        .frame(minWidth: compact ? 44 : 64)
        .opacity(day.excluded ? 0.55 : 1)
    }

    private func sessionEnd(_ day: HomeMonitoringResult.Day, _ session: HomeSession) -> Date {
        Calendar.current.date(byAdding: .hour, value: session == .morning ? 12 : 24, to: day.date)!
    }

    private func average(_ points: [BPPoint]) -> String? {
        guard !points.isEmpty else { return nil }
        let s = points.map(\.systolic).reduce(0, +) / Double(points.count)
        let d = points.map(\.diastolic).reduce(0, +) / Double(points.count)
        return "\(Int(s.rounded()))/\(Int(d.rounded()))"
    }
}

/// Picks the start day, session times and reminders.
private struct StartWeekSheet: View {
    let profile: Profile
    let onStart: (MeasurementWeek) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var morning = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date())!
    @State private var evening = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date())!
    @State private var reminders = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    DatePicker("First day", selection: $start, displayedComponents: .date)
                    DatePicker("Morning readings", selection: $morning, displayedComponents: .hourAndMinute)
                    DatePicker("Evening readings", selection: $evening, displayedComponents: .hourAndMinute)
                    Toggle("Remind me", isOn: $reminders)
                } footer: {
                    Text("Morning: before breakfast and before any blood-pressure medication. Evening: before dinner or bed. Sit quietly for five minutes, arm supported at heart level, then take two readings a minute apart.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Week") { startWeek() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func startWeek() {
        let week = MeasurementWeek(profileID: profile.uuid, start: start, morningMinutes: minutes(morning),
                                   eveningMinutes: minutes(evening), remindersEnabled: reminders)
        context.insert(week)
        try? context.save()
        let name = profile.name
        Task { await WeekReminders.schedule(week, profileName: name) }
        onStart(week)
        dismiss()
    }
}
