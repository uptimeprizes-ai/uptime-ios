import Foundation
import SwiftUI
import SwiftData

// MARK: - SettingsView
//
// The machine room (Android screen map §5, SettingsPage.kt): set the alarm,
// and the machinery around it — each part on its own brass plaque, in
// Android's order. It never lists a song and never sells anything.
// Sections that point at owned things are absent until the ninth counted
// Genesis morning. Copy is the shipping Android wording.
//
// Not yet here, pending their own passes: the Catalyst card and Special Day
// scheduler (the Catalyst cannot be owned on iOS until product ids exist),
// the theme selector, the permissions rows, and the alarm on/off toggle.

struct SettingsView: View {

    @Environment(\.modelContext) private var context
    @Query private var alarms: [AlarmEntity]
    @Query private var demoStates: [DemoStateEntity]

    @ObservedObject var alarmEngine: AlarmEngine

    @State private var pickerTime: Date = Calendar.current.date(from: DateComponents(hour: 7, minute: 0)) ?? Date()
    @State private var selectedRepeatDays: Set<Int> = []
    @State private var showJourneySelector: Bool = false
    @State private var showDebug: Bool = false
    @State private var referralInput: String = ""
    @State private var referralSaved: String? = ReferralCode.savedCode
    @State private var referralMessage: String?

    private var alarm: AlarmEntity? { alarms.first }
    private var catalogOpen: Bool {
        CatalogRules.isCatalogOpen(genesisCompletedDays: demoStates.first?.completedDays ?? 0)
    }

    var body: some View {
        ZStack {
            PaperBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    newAlarmCard
                    snoozeCard

                    SectionEyebrow(text: "ACTIVE ALARMS")
                    activeAlarmCard

                    if catalogOpen {
                        SectionEyebrow(text: "YOUR CATALOG")
                        yourCatalogCard
                    }

                    // One code, both phones (founder, 8 Nov 2026); label ruled
                    // the same as Android build 68. Not gated on day nine: a
                    // code entered on day one is in place for the first purchase.
                    SectionEyebrow(text: "REFERRAL CODE")
                    referralCard

                    SectionEyebrow(text: "ABOUT")
                    aboutCard

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear(perform: loadAlarm)
        .sheet(isPresented: $showJourneySelector) {
            JourneySelectorView()
        }
        .sheet(isPresented: $showDebug) {
            DebugView(alarmEngine: alarmEngine)
        }
    }

    // MARK: - ✦ NEW ALARM ✦

    private var newAlarmCard: some View {
        PlaqueCard {
            ZStack(alignment: .top) {
                HStack {
                    BrassScrew(size: 8)
                    Spacer()
                    BrassScrew(size: 8)
                }
                .offset(y: -4)
                Text("✦ NEW ALARM ✦")
                    .font(.playfair(12, semibold: true))
                    .tracking(2)
                    .foregroundColor(BrassPaper.brassHighlight)
                    .shadow(color: Color.black.opacity(0.60), radius: 1, x: 0, y: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }

            DatePicker("", selection: $pickerTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .colorScheme(.dark)
                .frame(maxWidth: .infinity)

            Spacer().frame(height: 10)
            Text("REPEAT")
                .font(.playfair(11))
                .tracking(2)
                .foregroundColor(BrassPaper.eyebrow)
            Spacer().frame(height: 6)
            HStack(spacing: 6) {
                ForEach(SettingsFormat.dayChips, id: \.value) { chip in
                    let selected = selectedRepeatDays.contains(chip.value)
                    Button { toggleRepeatDay(chip.value) } label: {
                        chipLabel(chip.label, selected: selected, size: 12)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .modifier(BrassChip(selected: selected, cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer().frame(height: 14)
            Button(action: setAlarm) {
                Text("SET ALARM")
                    .font(.playfair(14, semibold: true))
                    .tracking(4.2)
                    .foregroundColor(BrassPaper.raisedInk)
                    .shadow(color: BrassPaper.raisedLabelShadow, radius: 0, x: 0, y: 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .raisedBrass(cornerRadius: 8)
            }
            .buttonStyle(.plain)

            Spacer().frame(height: 6)
            Text(SettingsFormat.occurrenceText(
                trigger: SettingsFormat.nextTrigger(hour: pickerParts.hour, minute: pickerParts.minute, repeatDays: Array(selectedRepeatDays)),
                now: Date()
            ))
            .font(.playfair(12))
            .foregroundColor(BrassPaper.brassHighlight.opacity(0.85))
            .frame(maxWidth: .infinity)
        }
    }

    private var pickerParts: (hour: Int, minute: Int) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: pickerTime)
        return (parts.hour ?? 7, parts.minute ?? 0)
    }

    // MARK: - Snooze Duration

    private var snoozeCard: some View {
        PlaqueCard {
            Text("Snooze Duration")
                .font(.playfair(18, semibold: true))
                .foregroundColor(BrassPaper.brassHighlight.opacity(0.9))
                .plaqueTextShadow()
            Spacer().frame(height: 4)
            Text(CuratorCopy.snoozeSubtitle)
                .font(.playfair(14))
                .foregroundColor(BrassPaper.brassHighlight.opacity(0.85))
            Spacer().frame(height: 10)
            HStack(spacing: 6) {
                ForEach(AlarmEngine.snoozeOptions, id: \.self) { minutes in
                    let selected = minutes == (alarm?.snoozeMinutes ?? AlarmEngine.defaultSnoozeMinutes)
                    Button { setSnooze(minutes) } label: {
                        chipLabel("\(minutes) min", selected: selected, size: 13)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 8)
                            .modifier(BrassChip(selected: selected, cornerRadius: 100))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - ACTIVE ALARMS

    private var activeAlarmCard: some View {
        PlaqueCard {
            if let alarm, alarm.isEnabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HomeFormat.clock(hour: alarm.hour, minute: alarm.minute))
                            .font(.playfair(22, semibold: true))
                            .foregroundColor(BrassPaper.brassHighlight.opacity(0.9))
                            .plaqueTextShadow()
                        if !alarm.repeatDays.isEmpty {
                            Text(SettingsFormat.repeatDays(alarm.repeatDays))
                                .font(.playfair(12))
                                .foregroundColor(BrassPaper.brassHighlight.opacity(0.85))
                        }
                    }
                    Spacer()
                    Button(action: deleteAlarm) {
                        Text("Delete")
                            .font(.playfair(12))
                            .foregroundColor(BrassPaper.brassHighlight)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No alarms set yet. Your first alarm will live here.")
                    .font(.playfair(13))
                    .foregroundColor(BrassPaper.brassHighlight.opacity(0.85))
            }
        }
    }

    // MARK: - YOUR CATALOG

    private var yourCatalogCard: some View {
        Button { showJourneySelector = true } label: {
            PlaqueCard {
                Text("Active work")
                    .font(.playfair(15, semibold: true))
                    .foregroundColor(BrassPaper.brassHighlight.opacity(0.9))
                    .plaqueTextShadow()
                Spacer().frame(height: 4)
                Text("Switch between owned works")
                    .font(.playfair(12))
                    .foregroundColor(BrassPaper.brassHighlight.opacity(0.85))
                Spacer().frame(height: 6)
                Text("Switch \u{2192}")
                    .font(.playfair(13, semibold: true))
                    .foregroundColor(BrassPaper.brassHighlight)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - REFERRAL CODE
    //
    // Android's card (SettingsPage.kt ReferralCodeCard) in layout. Wording as
    // the founder sent it, 8 Nov 2026, after the device run: the 3.1.1 line
    // ("nothing in it for you, and nothing in the app changes") and "Saved
    // code:" are iOS's first; Android still carries its placeholder. The saved
    // message differs from Android's by design: the iPhone never reports the
    // code to a server, so there is nothing to wait on and nothing to confirm.
    // The refused-code line is still Android's placeholder.

    private var referralCard: some View {
        PlaqueCard {
            Text("Did someone send you?")
                .font(.playfair(15, semibold: true))
                .foregroundColor(BrassPaper.brassHighlight.opacity(0.9))
                .plaqueTextShadow()
            Spacer().frame(height: 4)
            Text("Enter their code and they are credited for anything you buy here. There is nothing in it for you, and nothing in the app changes.")
                .font(.playfair(12))
                .foregroundColor(BrassPaper.brassHighlight.opacity(0.85))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if let referralSaved {
                Spacer().frame(height: 6)
                Text("Saved code: \(referralSaved)")
                    .font(.playfair(13, semibold: true))
                    .foregroundColor(BrassPaper.brassHighlight)
            }
            Spacer().frame(height: 10)
            TextField("", text: $referralInput,
                      prompt: Text(referralSaved == nil ? "Code" : "Change code")
                        .foregroundColor(BrassPaper.brassHighlight.opacity(0.7)))
                .font(.playfair(15))
                .foregroundColor(BrassPaper.brassHighlight)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .onSubmit(saveReferral)
                .onChange(of: referralInput) { _, new in
                    if new.count > 64 { referralInput = String(new.prefix(64)) }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .sunkenBrass(cornerRadius: 8)
            Spacer().frame(height: 10)
            Button(action: saveReferral) {
                Text("SAVE CODE")
                    .font(.playfair(13, semibold: true))
                    .tracking(3.0)
                    .foregroundColor(BrassPaper.raisedInk)
                    .shadow(color: BrassPaper.raisedLabelShadow, radius: 0, x: 0, y: 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .raisedBrass(cornerRadius: 8)
            }
            .buttonStyle(.plain)
            if let referralMessage {
                Spacer().frame(height: 8)
                Text(referralMessage)
                    .font(.playfair(12))
                    .foregroundColor(BrassPaper.brassHighlight.opacity(0.9))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveReferral() {
        guard !referralInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let code = ReferralCode.save(referralInput) {
            referralSaved = code
            referralInput = ""
            referralMessage = "Saved. Code \(code) is on this phone."
        } else {
            referralMessage = ReferralCode.invalidMessage
        }
    }

    // MARK: - ABOUT

    private var aboutCard: some View {
        PlaqueCard {
            Text("UpTime Prizes")
                .font(.playfair(17, semibold: true))
                .foregroundColor(BrassPaper.brassHighlight.opacity(0.9))
                .plaqueTextShadow()
            Spacer().frame(height: 4)
            // Founder's wording, 8 Nov 2026. Android's About still reads
            // "A warm, slow-built morning experience…" until it is ported.
            Text("An alarm that wakes you with original music.\n\nEach morning arrives in three stages — The Invite, The Nudge, and The Prize. One song, and you do not choose it.")
                .font(.playfair(13))
                .foregroundColor(BrassPaper.brassHighlight.opacity(0.85))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            #if DEBUG
            Spacer().frame(height: 10)
            Button { showDebug = true } label: {
                Text("Debug tools")
                    .font(.playfair(13, semibold: true))
                    .foregroundColor(BrassPaper.brassHighlight)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            #endif
            Spacer().frame(height: 10)
            Text("Version \(appVersion)")
                .font(.playfair(11))
                .foregroundColor(BrassPaper.brassHighlight.opacity(0.55))
        }
    }

    // MARK: - Pieces

    private func chipLabel(_ text: String, selected: Bool, size: CGFloat) -> some View {
        Text(text)
            .font(.playfair(size, semibold: selected))
            .foregroundColor(selected ? BrassPaper.raisedInk : BrassPaper.brass2.opacity(0.6))
            .shadow(color: selected ? BrassPaper.raisedLabelShadow : Color.clear, radius: 0, x: 0, y: 1)
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: - Actions

    private func loadAlarm() {
        guard let alarm else { return }
        pickerTime = Calendar.current.date(from: DateComponents(hour: alarm.hour, minute: alarm.minute)) ?? pickerTime
        selectedRepeatDays = Set(alarm.repeatDays)
    }

    private func setAlarm() {
        guard let alarm else { return }
        let parts = pickerParts
        alarm.hour = parts.hour
        alarm.minute = parts.minute
        alarm.repeatDays = selectedRepeatDays.sorted()
        alarm.isEnabled = true
        try? context.save()
        alarmEngine.scheduleAlarm(hour: alarm.hour, minute: alarm.minute, repeatDays: alarm.repeatDays)
    }

    private func deleteAlarm() {
        guard let alarm else { return }
        alarm.isEnabled = false
        try? context.save()
        alarmEngine.cancelAlarm()
    }

    private func setSnooze(_ minutes: Int) {
        guard let alarm else { return }
        alarm.snoozeMinutes = minutes
        try? context.save()
    }

    private func toggleRepeatDay(_ day: Int) {
        if selectedRepeatDays.contains(day) {
            selectedRepeatDays.remove(day)
        } else {
            selectedRepeatDays.insert(day)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(version) (\(build))"
    }
}

/// A day chip or snooze pill: raised brass when chosen, sunken when not.
private struct BrassChip: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if selected {
            content.raisedBrass(cornerRadius: cornerRadius)
        } else {
            content.sunkenBrass(cornerRadius: cornerRadius)
        }
    }
}

// MARK: - SettingsFormat
//
// Settings' strings, computed as Android computes them. Pure, so tested.

enum SettingsFormat {
    struct DayChip {
        let label: String
        let value: Int
    }

    static let dayChips = [
        DayChip(label: "Sun", value: 1), DayChip(label: "Mon", value: 2), DayChip(label: "Tue", value: 3),
        DayChip(label: "Wed", value: 4), DayChip(label: "Thu", value: 5), DayChip(label: "Fri", value: 6),
        DayChip(label: "Sat", value: 7)
    ]

    /// "Mon, Wed, Fri"
    static func repeatDays(_ days: [Int]) -> String {
        days.sorted().compactMap { day in dayChips.first(where: { $0.value == day })?.label }.joined(separator: ", ")
    }

    /// When an alarm set to this time and these days will next sound.
    static func nextTrigger(hour: Int, minute: Int, repeatDays: [Int], now: Date = Date(), calendar: Calendar = .current) -> Date {
        var trigger = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if trigger <= now {
            trigger = calendar.date(byAdding: .day, value: 1, to: trigger) ?? trigger
        }
        if !repeatDays.isEmpty {
            for _ in 0..<7 {
                if repeatDays.contains(calendar.component(.weekday, from: trigger)) { break }
                trigger = calendar.date(byAdding: .day, value: 1, to: trigger) ?? trigger
            }
        }
        return trigger
    }

    /// "Tomorrow morning · in 19h 21m"
    static func occurrenceText(trigger: Date, now: Date, calendar: Calendar = .current) -> String {
        let diffMinutes = Int(trigger.timeIntervalSince(now) / 60)
        guard trigger > now else { return "Now" }
        let hours = diffMinutes / 60
        let minutes = diffMinutes % 60

        let dayPart: String
        if calendar.isDate(trigger, inSameDayAs: now) {
            dayPart = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(trigger, inSameDayAs: tomorrow) {
            dayPart = "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "EEEE"
            dayPart = formatter.string(from: trigger)
        }

        let hour = calendar.component(.hour, from: trigger)
        let timePart = hour < 12 ? "morning" : (hour < 17 ? "afternoon" : "evening")

        let relPart: String
        if hours > 0 && minutes > 0 {
            relPart = "in \(hours)h \(minutes)m"
        } else if hours > 0 {
            relPart = "in \(hours)h"
        } else if minutes > 0 {
            relPart = "in \(minutes)m"
        } else {
            relPart = "now"
        }
        return "\(dayPart) \(timePart) · \(relPart)"
    }
}

// MARK: - JourneySelectorView
//
// Choose the active journey (screen map §6). Only one is active at a time;
// switching preserves every journey's progress exactly — activation changes
// which is active, nothing else. The Catalyst Tracks are not a journey and
// are not listed.

struct JourneySelectorView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \JourneyEntity.sortOrder) private var journeys: [JourneyEntity]

    private var ownedJourneys: [JourneyEntity] {
        journeys.filter { $0.id != CatalogRules.catalystId && $0.purchaseState != "NOT_OWNED" }
    }

    var body: some View {
        NavigationStack {
            List {
                if ownedJourneys.isEmpty {
                    Text("No purchased works yet. The catalog opens on day nine.")
                        .foregroundColor(Color("ink").opacity(0.6))
                } else {
                    Section {
                        ForEach(ownedJourneys, id: \.id) { journey in
                            Button { activate(journey) } label: {
                                HStack {
                                    Text(journey.title)
                                        .font(.custom("PlayfairDisplay-SemiBold", size: 16))
                                        .foregroundColor(Color("ink"))
                                    Spacer()
                                    if journey.isActive {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Color("brass"))
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Only one journey can be active at a time. Your progress is saved when switching.")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color("brass"))
                }
            }
        }
    }

    private func activate(_ chosen: JourneyEntity) {
        for journey in journeys {
            journey.isActive = journey.id == chosen.id
        }
        try? context.save()
    }
}
