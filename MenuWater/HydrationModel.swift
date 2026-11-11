import AppKit
import ApplicationServices
import Foundation
import Observation
import ServiceManagement

enum VolumeUnit: String, CaseIterable, Identifiable {
    case metric
    case imperial
    case american

    var id: Self { self }

    var symbol: String {
        switch self {
        case .metric:
            "ml"
        case .imperial, .american:
            "oz"
        }
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .metric:
            "ml (Metric)"
        case .imperial:
            "oz (Imperial)"
        case .american:
            "oz (American)"
        }
    }

    var millilitersPerUnit: Double {
        switch self {
        case .metric:
            1
        case .imperial:
            28.413_062_5
        case .american:
            29.573_529_562_5
        }
    }
}

enum ProfileGender: String, CaseIterable, Identifiable {
    case female
    case male

    var id: Self { self }

    var displayName: LocalizedStringResource {
        switch self {
        case .female:
            "Female"
        case .male:
            "Male"
        }
    }
}

@MainActor
@Observable
final class HydrationModel {
    private enum Keys {
        static let count = "hydration.count"
        static let date = "hydration.date"
        static let interval = "reminder.interval"
        static let volumeML = "container.volumeML"
        static let unit = "container.unit"
        static let hasDisplayNotch = "display.hasNotch"
        static let fullScreenReminder = "reminder.fullScreen"
        static let intensiveReminder = "reminder.intensive"
        static let age = "profile.age"
        static let gender = "profile.gender"
    }

    var count: Int
    var intervalMinutes: Int
    var volumeML: Double
    var volumeUnit: VolumeUnit
    var launchAtLogin: Bool
    var hasDisplayNotch: Bool
    var fullScreenReminder: Bool
    var intensiveReminder: Bool
    var age: Int
    var gender: ProfileGender
    var errorMessage: String?
    var isShowingAccessibilityInstructions = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private lazy var reminderPresenter = ReminderPresenter()
    @ObservationIgnored private var reminderTimer: Timer?
    @ObservationIgnored private var midnightTimer: Timer?

    let intervalOptions = [15, 30, 45, 60, 90, 120]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        count = defaults.integer(forKey: Keys.count)
        let savedInterval = defaults.object(forKey: Keys.interval) as? Int ?? 60
        intervalMinutes = intervalOptions.contains(savedInterval) ? savedInterval : 60
        volumeML = defaults.object(forKey: Keys.volumeML) as? Double ?? 350
        volumeUnit = Self.savedVolumeUnit(from: defaults)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        hasDisplayNotch = defaults.bool(forKey: Keys.hasDisplayNotch)
        fullScreenReminder = defaults.bool(forKey: Keys.fullScreenReminder)
        intensiveReminder = defaults.bool(forKey: Keys.intensiveReminder) && AXIsProcessTrusted()
        age = defaults.object(forKey: Keys.age) as? Int ?? 30
        gender = ProfileGender(rawValue: defaults.string(forKey: Keys.gender) ?? "") ?? .female

        resetIfNeeded()
        scheduleMidnightReset()
        scheduleReminder()
    }

    var totalML: Double {
        Double(count) * volumeML
    }

    var displayedContainerVolume: Double {
        volumeML / volumeUnit.millilitersPerUnit
    }

    var displayedTotal: Double {
        totalML / volumeUnit.millilitersPerUnit
    }

    var displayedDailyGoal: Double {
        dailyGoalML / volumeUnit.millilitersPerUnit
    }

    var hasReachedDailyGoal: Bool {
        totalML >= dailyGoalML
    }

    private var dailyGoalML: Double {
        switch age {
        case ...3:
            900
        case 4...8:
            1_200
        case 9...13:
            gender == .male ? 1_800 : 1_600
        case 14...18:
            gender == .male ? 2_600 : 1_800
        default:
            gender == .male ? 3_000 : 2_200
        }
    }

    func addContainer() {
        resetIfNeeded()
        count += 1
        saveCount()
    }

    func removeContainer() {
        resetIfNeeded()
        count = max(0, count - 1)
        saveCount()
    }

    func updateInterval(_ minutes: Int) {
        guard intervalOptions.contains(minutes), minutes != intervalMinutes else {
            return
        }
        intervalMinutes = minutes
        defaults.set(minutes, forKey: Keys.interval)
        scheduleReminder()
    }

    func updateVolume(_ displayedValue: Double) {
        volumeML = displayedValue * volumeUnit.millilitersPerUnit
        defaults.set(volumeML, forKey: Keys.volumeML)
    }

    func updateUnit(_ unit: VolumeUnit) {
        volumeUnit = unit
        defaults.set(unit.rawValue, forKey: Keys.unit)
    }

    func updateAge(_ newAge: Int) {
        age = newAge
        defaults.set(newAge, forKey: Keys.age)
    }

    func updateGender(_ newGender: ProfileGender) {
        gender = newGender
        defaults.set(newGender.rawValue, forKey: Keys.gender)
    }

    func updateDisplayNotch(_ enabled: Bool) {
        hasDisplayNotch = enabled
        defaults.set(enabled, forKey: Keys.hasDisplayNotch)
    }

    func updateFullScreenReminder(_ enabled: Bool) {
        fullScreenReminder = enabled
        defaults.set(enabled, forKey: Keys.fullScreenReminder)
    }

    func updateIntensiveReminder(_ enabled: Bool) {
        guard enabled else {
            intensiveReminder = false
            defaults.set(false, forKey: Keys.intensiveReminder)
            errorMessage = nil
            return
        }

        guard AXIsProcessTrusted() else {
            intensiveReminder = false
            defaults.set(false, forKey: Keys.intensiveReminder)
            errorMessage = nil
            isShowingAccessibilityInstructions = true
            return
        }

        intensiveReminder = enabled
        defaults.set(enabled, forKey: Keys.intensiveReminder)
        errorMessage = nil
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = String(localized: "Couldn’t update the launch-at-login setting.")
        }
    }

    func refreshForToday() {
        resetIfNeeded()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showReminderNow() {
        reminderPresenter.show(
            hasDisplayNotch: hasDisplayNotch,
            fullScreen: fullScreenReminder,
            intensive: intensiveReminder
        )
    }

    private static func savedVolumeUnit(from defaults: UserDefaults) -> VolumeUnit {
        let savedValue = defaults.string(forKey: Keys.unit)

        if savedValue == "ounces" {
            return .american
        }

        if savedValue == "milliliters" {
            return .metric
        }

        return VolumeUnit(rawValue: savedValue ?? "") ?? .metric
    }

    func openAccessibilitySettings() {
        isShowingAccessibilityInstructions = false
        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }

        NSWorkspace.shared.open(settingsURL)
    }

    func dismissAccessibilityInstructions() {
        isShowingAccessibilityInstructions = false
    }

    private func resetIfNeeded() {
        let today = Calendar.current.startOfDay(for: .now)
        let savedDate = defaults.object(forKey: Keys.date) as? Date

        guard savedDate.map({ !Calendar.current.isDate($0, inSameDayAs: today) }) ?? true else {
            return
        }

        count = 0
        saveCount()
    }

    private func saveCount() {
        defaults.set(count, forKey: Keys.count)
        defaults.set(Calendar.current.startOfDay(for: .now), forKey: Keys.date)
    }

    private func scheduleReminder() {
        reminderTimer?.invalidate()

        let timer = Timer(
            timeInterval: TimeInterval(intervalMinutes * 60),
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.reminderPresenter.show(
                    hasDisplayNotch: self.hasDisplayNotch,
                    fullScreen: self.fullScreenReminder,
                    intensive: self.intensiveReminder
                )
            }
        }

        // Coalesce background wakeups without noticeably delaying a reminder.
        timer.tolerance = 5
        reminderTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleMidnightReset() {
        midnightTimer?.invalidate()

        let calendar = Calendar.current
        guard let nextMidnight = calendar.nextDate(
            after: .now,
            matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) else {
            return
        }

        midnightTimer = Timer(fire: nextMidnight, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetIfNeeded()
                self?.scheduleMidnightReset()
            }
        }

        if let midnightTimer {
            midnightTimer.tolerance = 1
            RunLoop.main.add(midnightTimer, forMode: .common)
        }
    }
}
