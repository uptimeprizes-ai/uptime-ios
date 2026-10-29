import Foundation
import SwiftData

// MARK: - MorningStarter
//
// Build 33 experiment (founder, 2026-09-25, "option one"): a Dismiss on the
// AlarmKit lock screen starts the morning's song straight away, while the
// phone is still locked. The app's UI is not needed for that — it shows the
// running stage whenever the person opens it.
//
// The audio player and stage coordinator live here, one instance each, so
// the lock-screen intent and the app's screens drive the same morning.

@MainActor
enum MorningStarter {

    static let audio: AudioPlayerManager = {
        let manager = AudioPlayerManager()
        manager.onCardPause = { MorningStarter.cardPaused() }
        manager.onCardResume = { MorningStarter.cardResumed() }
        return manager
    }()
    static let stages = StageCoordinator()

    // MARK: - Downloaded music is found before a song is chosen

    /// Looks up where every owned journey's downloaded music is, before a
    /// morning picks its song. When the doorbell's answer cold-launches the
    /// app, the song used to be chosen first: the journey's files were on
    /// the phone but not yet looked up, so a Genesis song stood in and the
    /// journey did not move (founder's phone, 29 Oct 11:39:21 — warm-front
    /// reported 8/8 on this phone 45 seconds later). Each journey's result
    /// is logged by DeliveryManager, so the lookup is visible before the song.
    static func lookUpDownloadedMusic() async {
        let context = UpTimePrizesApp.sharedContainer.mainContext
        let owned = ((try? context.fetch(FetchDescriptor<JourneyEntity>())) ?? [])
            .filter { $0.purchaseState != "NOT_OWNED" }
            .map(\.id)
        await DeliveryManager.shared.refresh(ownedJourneyIds: owned)
    }

    // MARK: - The card's pause is the snooze (founder, 2026-10-09)

    /// A snooze set by the card's pause that has neither returned nor been
    /// taken back.
    private static var cardPauseSnoozePending = false

    /// The card paused the morning. In the Invite and the Nudge that is the
    /// snooze: the return is set now, as a system alarm, so it sounds even
    /// if iOS puts the paused app to sleep. In the Prize it is only a pause.
    static func cardPaused() {
        let stage = StageCoordinator.ruleName(for: stages.currentStage)
        guard stages.currentSong != nil, RingDecision.cardPauseSnoozes(stage: stage) else {
            UpTimeLog.alarm.notice("[ALARM] card pause in the \(stage, privacy: .public) — only a pause, no snooze")
            return
        }
        stages.holdRingLimit()
        engine().snoozeAlarm(stageAtSnooze: stage)
        cardPauseSnoozePending = true
        UpTimeLog.alarm.notice("[ALARM] card pause in the \(stage, privacy: .public) — snoozed; play takes it back")
    }

    /// The card played the morning again before the snooze returned: the
    /// snooze is taken back and the song carries on.
    static func cardResumed() {
        guard cardPauseSnoozePending else { return }
        cardPauseSnoozePending = false
        engine().withdrawSnooze()
        stages.releaseRingLimit()
        UpTimeLog.alarm.notice("[ALARM] card play — the pause's snooze is taken back")
    }

    /// The person settled the morning in the app. A Dismiss takes back a
    /// snooze the card's pause set, so the doorbell never returns to a
    /// finished morning; a Snooze simply replaces it.
    static func settleCardPause(dismissed: Bool) {
        guard cardPauseSnoozePending else { return }
        cardPauseSnoozePending = false
        if dismissed { engine().withdrawSnooze() }
    }

    private static func engine() -> AlarmEngine {
        AlarmEngine(context: UpTimePrizesApp.sharedContainer.mainContext)
    }

    /// The morning counted by a lock-screen answer, kept for the Prize
    /// screen if the person later opens the app and dismisses.
    private static var answeredOutcome: (day: String, outcome: AlarmEngine.MorningOutcome)?

    /// Today's lock-screen-counted morning, once; nil if there is none.
    static func consumeAnsweredOutcome(now: Date = Date()) -> AlarmEngine.MorningOutcome? {
        defer { answeredOutcome = nil }
        guard let saved = answeredOutcome, saved.day == MorningLedger.dayKey(for: now) else { return nil }
        return saved.outcome
    }

    /// Starts today's song at the stage a snooze sent forward (the Invite
    /// otherwise). Does nothing if a morning is already playing; a morning
    /// that finished unseen is cleared first, so it can never block the next.
    static func startFromLockScreen() {
        guard !audio.isPlaying else { return }
        // A snooze the card's pause set has returned and been answered.
        cardPauseSnoozePending = false
        if stages.currentSong != nil { stages.stopAlarm() }
        let engine = AlarmEngine(context: UpTimePrizesApp.sharedContainer.mainContext)
        guard let song = engine.currentSong(from: audio) else {
            UpTimeLog.alarm.error("[ALARM] lock screen: no song for today — nothing to play")
            return
        }
        // Until the app's screen takes over, an unanswered ring ends the
        // same way it does in the app (Option B) — minus the on-screen note.
        stages.onRingLimit = { stage in
            switch RingDecision.onRingLimitReached(stage: stage, autoSnoozeUsed: engine.autoSnoozeUsed) {
            case .autoSnooze:
                engine.autoSnooze(stageAtSnooze: stage)
                stages.stopAlarm()
            case .stopAndReport:
                // The morning already counted when it was answered.
                stages.stopAlarm()
            case .keepRinging:
                break
            }
        }
        stages.startAlarm(
            song: song,
            subdirectory: engine.subdirectory(for: song.journeyId),
            audioManager: audio,
            startingAt: StageCoordinator.stage(forRuleName: engine.consumeResumeStage())
        )
        UpTimeLog.alarm.notice("[ALARM] lock screen: morning started without opening the app")

        // Founder ruling 2026-09-26: answering the doorbell and hearing the
        // song counts the morning, whether or not the app is ever opened.
        // (A Dismiss more than 30 minutes late never reaches this point.)
        if let outcome = engine.handleAlarmDismissed(
            audioSounded: stages.audioSounded,
            stageAtDismiss: StageCoordinator.ruleName(for: stages.currentStage),
            reachedPrize: stages.currentStage == .stage3
        ) {
            answeredOutcome = (MorningLedger.dayKey(for: Date()), outcome)
        }
    }
}

extension AlarmEngine.MorningOutcome {
    /// The same morning, noting that the Prize has now been reached.
    func reachingPrize(_ reached: Bool) -> AlarmEngine.MorningOutcome {
        AlarmEngine.MorningOutcome(
            journeyTitle: journeyTitle,
            morningNumber: morningNumber,
            totalDays: totalDays,
            journeyComplete: journeyComplete,
            reachedPrize: reachedPrize || reached,
            heldStreakOnly: heldStreakOnly,
            wasUnanswered: wasUnanswered
        )
    }
}
