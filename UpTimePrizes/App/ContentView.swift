import SwiftUI
import SwiftData
import StoreKit
import UserNotifications

// MARK: - NotificationDelegate

/// Handles foreground notification delivery and routes alarm notifications
/// to the in-app alarm UI.
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, ObservableObject {

    var onAlarmFired: (() -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.userInfo["type"] as? String == "alarm" {
            DispatchQueue.main.async {
                self.onAlarmFired?()
                NotificationCenter.default.post(name: AlarmEngine.alarmFiredNotificationName, object: nil)
            }
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo["type"] as? String == "alarm" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AlarmEngine.alarmFiredNotificationName, object: nil)
            }
        }
        completionHandler()
    }
}

// MARK: - ContentView

struct ContentView: View {

    // MARK: - Environment

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Observed

    @ObservedObject var audioManager: AudioPlayerManager
    @ObservedObject var stageCoordinator: StageCoordinator
    @ObservedObject var storeKit: StoreKitManager
    @Binding var showAlarm: Bool

    // MARK: - State

    @State private var alarmEngine: AlarmEngine?
    @State private var isSeeded: Bool = false
    @State private var prizeOutcome: AlarmEngine.MorningOutcome?
    @State private var prizeSongId: String?
    @State private var prizeSongTitle: String = ""
    @State private var snoozeReturnAt: Date?
    @State private var showMissedAlarm: Bool = false
    @State private var missedSounded: Bool = true
    /// Android WelcomePage: shown once, before the main interface.
    @AppStorage("com.uptimeprizes.welcomeSeen") private var welcomeSeen: Bool = false
    /// Android DayNineTransitionDialog: shown once, when the catalog opens.
    @AppStorage("com.uptimeprizes.dayNineSeen") private var dayNineSeen: Bool = false
    @Query private var demoStates: [DemoStateEntity]

    private var catalogOpen: Bool {
        guard let demo = demoStates.first else { return false }
        return demo.isPurchaseOffered || CatalogRules.isCatalogOpen(genesisCompletedDays: demo.completedDays)
    }
    @StateObject private var notificationDelegate = NotificationDelegate()
    @Environment(\.requestReview) private var requestReview

    // MARK: - Body

    var body: some View {
        Group {
            if isSeeded, let engine = alarmEngine {
                HomeView(
                    alarmEngine: engine,
                    audioManager: audioManager,
                    stageCoordinator: stageCoordinator,
                    storeKit: storeKit
                )
                .fullScreenCover(isPresented: $showAlarm) {
                    // The Prize screen is presented inside the same cover as
                    // the alarm, so the alarm screen can never close before
                    // the Prize screen renders (Android bug guard 1, §2.5).
                    if let returnAt = snoozeReturnAt {
                        SnoozeConfirmationView(returnAt: returnAt) {
                            snoozeReturnAt = nil
                            showAlarm = false
                        }
                    } else if let outcome = prizeOutcome {
                        PrizeView(outcome: outcome, songId: prizeSongId, songTitle: prizeSongTitle) {
                            prizeOutcome = nil
                            showAlarm = false
                            maybeRequestReview()
                        }
                    } else {
                        AlarmView(
                            stageCoordinator: stageCoordinator,
                            audioManager: audioManager,
                            onDismiss: {
                                // Captured before stopAlarm clears it: the
                                // Prize screen offers a star for this song.
                                prizeSongId = stageCoordinator.currentSong?.id
                                prizeSongTitle = stageCoordinator.currentSong?.title ?? ""
                                let stage = stageCoordinator.currentStage
                                MorningStarter.settleCardPause(dismissed: true)
                                let outcome = engine.handleAlarmDismissed(
                                    audioSounded: stageCoordinator.audioSounded,
                                    stageAtDismiss: stageName(for: stage),
                                    reachedPrize: stage == .stage3 || stage == .replay
                                )
                                stageCoordinator.stopAlarm()
                                if let outcome {
                                    prizeOutcome = outcome
                                } else if let answered = MorningStarter.consumeAnsweredOutcome() {
                                    // Counted when answered on the lock screen.
                                    prizeOutcome = answered.reachingPrize(stage == .stage3 || stage == .replay)
                                } else {
                                    // Nothing sounded or the day already has
                                    // its morning — no count, no Prize screen.
                                    showAlarm = false
                                }
                            },
                            onSnooze: {
                                MorningStarter.settleCardPause(dismissed: false)
                                engine.snoozeAlarm(stageAtSnooze: stageName(for: stageCoordinator.currentStage))
                                stageCoordinator.stopAlarm()
                                // "Rest a little longer." for three seconds, then back to the app.
                                snoozeReturnAt = Date().addingTimeInterval(TimeInterval(engine.snoozeMinutes * 60))
                            }
                        )
                    }
                }
                .onChange(of: showAlarm) { _, newValue in
                    if newValue {
                        prizeOutcome = nil
                        snoozeReturnAt = nil
                        engine.beginAlarmSession()
                        // Option B: what happens when a ring goes unanswered.
                        stageCoordinator.onRingLimit = { stage in
                            switch RingDecision.onRingLimitReached(stage: stage, autoSnoozeUsed: engine.autoSnoozeUsed) {
                            case .autoSnooze:
                                engine.autoSnooze(stageAtSnooze: stage)
                                stageCoordinator.stopAlarm()
                                showAlarm = false
                            case .stopAndReport:
                                // Founder ruling 2026-09-25: nobody answered,
                                // so the morning does NOT count - no progress,
                                // no streak, no Prize screen. It is reported.
                                engine.endUnansweredSession()
                                stageCoordinator.stopAlarm()
                                showAlarm = false
                                missedSounded = true
                                showMissedAlarm = true
                            case .keepRinging:
                                break
                            }
                        }
                        if (audioManager.isPlaying || audioManager.isPaused) && stageCoordinator.currentSong != nil {
                            // Already playing — started from the lock screen.
                        } else {
                            // The downloaded music is looked up before the
                            // song is chosen (a cold launch otherwise picks
                            // a Genesis stand-in for a song on the phone).
                            Task { @MainActor in
                                await MorningStarter.lookUpDownloadedMusic()
                                // Started another way while looking? Then
                                // that morning is the one; never start twice.
                                guard !((audioManager.isPlaying || audioManager.isPaused) && stageCoordinator.currentSong != nil),
                                      let song = engine.currentSong(from: audioManager) else { return }
                                let sub = engine.subdirectory(for: song.journeyId)
                                // A snooze return resumes one stage further (§2.1).
                                stageCoordinator.startAlarm(
                                    song: song,
                                    subdirectory: sub,
                                    audioManager: audioManager,
                                    startingAt: StageCoordinator.stage(forRuleName: engine.consumeResumeStage())
                                )
                            }
                        }
                    }
                }
                // Bug 1 fix: Re-verify alarm scheduling every time the app becomes active.
                // This catches cases where the OS cleared pending notifications (e.g., after
                // an app update from TestFlight/App Store).
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        ProgressBackup.save(context: context, reason: "background")
                    }
                    if newPhase == .active {
                        startPendingMorningIfAny()
                        judgeUnattendedMorning()
                        Task {
                            await engine.verifyAndRescheduleIfNeeded()
                        }
                    }
                }
            } else {
                ProgressView()
                    .tint(Color("brass"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PaperBackground())
            }
        }
        .overlay {
            if !welcomeSeen {
                WelcomeView { welcomeSeen = true }
            } else if catalogOpen && !dayNineSeen {
                DayNineView {
                    dayNineSeen = true
                    UpTimeLog.seed.notice("[SEED] day-nine screen seen — the catalog is open")
                }
            }
        }
        .task {
            await setup()
        }
        // A missed morning is reported once, in the app (§2.3). It never
        // counts (founder ruling 2026-09-25). Both lines are ruled now: the
        // 2026-09-17 "The morning counts." is retired, and the 2026-10-09
        // replacement states the ruling truthfully.
        .alert(CuratorCopy.missedAlarmTitle, isPresented: $showMissedAlarm) {
            Button(CuratorCopy.prizeContinue, role: .cancel) {}
        } message: {
            Text(missedSounded
                 ? CuratorCopy.missedAlarmSoundedUnansweredBody
                 : CuratorCopy.missedAlarmSilentBody)
        }
    }

    // MARK: - Setup

    @MainActor
    private func setup() async {
        // Bug 3 fix: Exclude SwiftData store from iCloud backup to prevent
        // stale region data from being restored on device migration.
        BackupExclusion.excludeSwiftDataStoreFromBackup()

        // Seed database (with manifest fingerprint check for Bug 3)
        DatabaseSeeder.seed(context: context)
        // A restored or new phone: bring progress back before anything reads it.
        ProgressBackup.restoreIfFresh(context: context)
        isSeeded = true

        // Create AlarmEngine
        let engine = AlarmEngine(context: context)
        alarmEngine = engine

        // Configure StoreKit with the model context: fetch products, restore purchases.
        storeKit.configure(context: context)

        // Which owned journeys' music is already on this phone.
        let owned = ((try? context.fetch(FetchDescriptor<JourneyEntity>())) ?? [])
            .filter { $0.purchaseState != "NOT_OWNED" }
            .map(\.id)
        Task { await DeliveryManager.shared.refresh(ownedJourneyIds: owned) }

        // Bug 1 fix: Reschedule alarm from persisted state on first launch
        engine.rescheduleFromPersistedState()

        // Set up notification delegate
        notificationDelegate.onAlarmFired = { [weak engine] in
            engine?.isAlarmActive = true
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate

        // Request notification permission on first launch
        _ = await engine.requestNotificationPermission()

        // A Dismiss on the AlarmKit lock screen that cold-launched the app
        // left a start request; the UI is ready now, so honour it.
        startPendingMorningIfAny()
        judgeUnattendedMorning()
        ProgressBackup.save(context: context, reason: "launch")
    }

    /// Reports the most recent AlarmKit morning nobody answered, once.
    private func judgeUnattendedMorning() {
        guard let engine = alarmEngine, !showAlarm, !showMissedAlarm else { return }
        switch engine.checkUnattendedMorning() {
        case .missed(let sounded):
            missedSounded = sounded
            showMissedAlarm = true
        case .nothing:
            break
        }
    }

    /// Starts the in-app morning if an AlarmKit Dismiss asked for it.
    private func startPendingMorningIfAny() {
        #if canImport(AlarmKit)
        // Opening the app while the doorbell still rings answers it, exactly
        // as its button does.
        if #available(iOS 26.0, *) {
            // Verification protocol, rule 4: say what was found on every
            // return to the app, not only when it acts.
            let ringing = LockScreenAnswer.isRinging
            UpTimeLog.alarm.notice("[ALARM] app forward: alarm ringing=\(ringing, privacy: .public) alarm screen shown=\(showAlarm, privacy: .public)")
            if !showAlarm, ringing {
                Task { await LockScreenAnswer.answer(how: "app opened while the alarm rang") }
                return
            }
        }
        #endif
        let pending = PendingMorningStart.consume()
        // Playing, or paused from the lock-screen card: the morning is on.
        let playing = (audioManager.isPlaying || audioManager.isPaused) && stageCoordinator.currentSong != nil
        UpTimeLog.alarm.notice("[ALARM] app forward: start request=\(pending, privacy: .public) song playing=\(playing, privacy: .public)")
        guard pending || playing, !showAlarm else { return }
        NotificationCenter.default.post(name: AlarmEngine.alarmFiredNotificationName, object: nil)
    }

    // MARK: - Helpers

    private func stageName(for stage: StageCoordinator.Stage) -> String {
        switch stage {
        case .stage1: return "invite"
        case .stage2: return "nudge"
        case .stage3, .replay: return "prize"
        }
    }

    /// Review prompt (§2.6): asks only from a normal app screen after the
    /// alarm flow has fully ended — never during an alarm or while audio
    /// plays. requestReview needs no permission (Android bug guard 2: no
    /// permission-requiring calls on the post-alarm path).
    private func maybeRequestReview() {
        let ledger = MorningLedger(context: context)
        let eligible = ReviewPromptManager.shouldAsk(
            soundedMornings: ledger.soundedMorningsCount(),
            attemptsSoFar: ReviewPromptManager.attempts(),
            lastCountedMorningIsRecent: ledger.lastCountedDayIsTodayOrYesterday(),
            alarmActive: alarmEngine?.isAlarmActive ?? false,
            audioPlaying: audioManager.isPlaying,
            hasUnacknowledgedMissedAlarm: false // missed-alarm pass not yet built (§2.7)
        )
        guard eligible else { return }
        ReviewPromptManager.recordAttempt()
        requestReview()
    }
}
