import AppKit
import SwiftUI

struct ContentView: View {
    let model: HydrationModel

    var body: some View {
        VStack(spacing: 16) {
            HydrationSummary(
                count: model.count,
                total: model.displayedTotal,
                goal: model.displayedDailyGoal,
                unit: model.volumeUnit,
                hasReachedGoal: model.hasReachedDailyGoal,
                onRemove: model.removeContainer,
                onAdd: model.addContainer
            )

            Divider()

            ReminderControls(
                intervalMinutes: model.intervalMinutes,
                intervalOptions: model.intervalOptions,
                onIntervalChange: model.updateInterval
            )

            ContainerSettings(
                displayedVolume: model.displayedContainerVolume,
                unit: model.volumeUnit,
                hasDisplayNotch: model.hasDisplayNotch,
                fullScreenReminder: model.fullScreenReminder,
                intensiveReminder: model.intensiveReminder,
                launchAtLogin: model.launchAtLogin,
                age: model.age,
                gender: model.gender,
                onVolumeChange: model.updateVolume,
                onUnitChange: model.updateUnit,
                onDisplayNotchChange: model.updateDisplayNotch,
                onFullScreenReminderChange: model.updateFullScreenReminder,
                onIntensiveReminderChange: model.updateIntensiveReminder,
                onLaunchAtLoginChange: model.updateLaunchAtLogin,
                onAgeChange: model.updateAge,
                onGenderChange: model.updateGender,
                onTryNow: model.showReminderNow
            )

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Quit Water Reminder") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            model.refreshForToday()
        }
        .alert(
            "Accessibility Access Required",
            isPresented: Binding(
                get: { model.isShowingAccessibilityInstructions },
                set: { isPresented in
                    if !isPresented {
                        model.dismissAccessibilityInstructions()
                    }
                }
            )
        ) {
            Button("Open Settings") {
                model.openAccessibilitySettings()
            }

            Button("Not Now", role: .cancel) {
                model.dismissAccessibilityInstructions()
            }
        } message: {
            Text(
                "To use Intensive reminder:\n\n1. Open Accessibility settings.\n2. Find Water Reminder in the list.\n3. Turn its switch on.\n4. Return here and enable Intensive reminder again.\n\nThis access is used only to receive the displayed five-key sequence while an intensive reminder is visible."
            )
        }
    }
}

private struct HydrationSummary: View {
    let count: Int
    let total: Double
    let goal: Double
    let unit: VolumeUnit
    let hasReachedGoal: Bool
    let onRemove: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "drop.fill")
                .font(.title)
                .foregroundStyle(.blue)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(total, format: amountFormat)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(hasReachedGoal ? .blue : .primary)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: total)

                Text("/")

                Text(goal, format: amountFormat)
                    .font(.headline)
                    .monospacedDigit()

                Text(unit.symbol)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            if hasReachedGoal {
                Text("You’ve reached the daily goal!")
                    .font(.caption)
                    .foregroundStyle(.blue.opacity(0.5))
                    .transition(.opacity)
            }

            HStack(spacing: 14) {
                Button(action: onRemove) {
                    Image(systemName: "minus")
                }
                .disabled(count == 0)
                .accessibilityLabel("Remove one container")

                Text("\(count)")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: count)
                    .frame(minWidth: 28)
                    .accessibilityLabel("\(count) containers today")

                Button(action: onAdd) {
                    Image(systemName: "plus")
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Add one container")
            }
            .controlSize(.large)
        }
        .animation(.easeInOut(duration: 0.25), value: hasReachedGoal)
    }

    private var amountFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(unit == .metric ? 0 : 1))
    }
}

private struct ReminderControls: View {
    let intervalMinutes: Int
    let intervalOptions: [Int]
    let onIntervalChange: (Int) -> Void

    var body: some View {
        Picker(
            "Remind me every",
            selection: Binding(
                get: { intervalMinutes },
                set: onIntervalChange
            )
        ) {
            ForEach(intervalOptions, id: \.self) { minutes in
                Text(intervalLabel(minutes))
                    .tag(minutes)
            }
        }
    }

    private func intervalLabel(_ minutes: Int) -> String {
        if minutes < 60 {
            return String(localized: "\(minutes) min")
        }

        let hours = Double(minutes) / 60
        return String(localized: "\(hours, format: .number.precision(.fractionLength(hours.rounded() == hours ? 0 : 1))) hr")
    }
}

private struct ContainerSettings: View {
    let displayedVolume: Double
    let unit: VolumeUnit
    let hasDisplayNotch: Bool
    let fullScreenReminder: Bool
    let intensiveReminder: Bool
    let launchAtLogin: Bool
    let age: Int
    let gender: ProfileGender
    let onVolumeChange: (Double) -> Void
    let onUnitChange: (VolumeUnit) -> Void
    let onDisplayNotchChange: (Bool) -> Void
    let onFullScreenReminderChange: (Bool) -> Void
    let onIntensiveReminderChange: (Bool) -> Void
    let onLaunchAtLoginChange: (Bool) -> Void
    let onAgeChange: (Int) -> Void
    let onGenderChange: (ProfileGender) -> Void
    let onTryNow: () -> Void

    @AppStorage("ui.containerSettingsExpanded") private var isContainerExpanded = false
    @AppStorage("ui.myInfoExpanded") private var isMyInfoExpanded = false
    @AppStorage("ui.optionsExpanded") private var isOptionsExpanded = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    isContainerExpanded.toggle()
                }
            } label: {
                SettingsRowLabel(title: "Container size", systemImage: "waterbottle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isContainerExpanded {
                Stepper(
                    value: Binding(
                        get: { displayedVolume },
                        set: onVolumeChange
                    ),
                    in: volumeRange,
                    step: volumeStep
                ) {
                    HStack {
                        Text("Container")

                        Spacer()

                        Text(displayedVolume, format: amountFormat)
                            .monospacedDigit()

                        Text(unit.symbol)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                withAnimation(.snappy) {
                    isMyInfoExpanded.toggle()
                }
            } label: {
                SettingsRowLabel(title: "My Info", systemImage: "person.crop.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isMyInfoExpanded {
                MyInfoSettings(
                    age: age,
                    gender: gender,
                    unit: unit,
                    onAgeChange: onAgeChange,
                    onGenderChange: onGenderChange,
                    onUnitChange: onUnitChange
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    onTryNow()
                } else {
                    withAnimation(.snappy) {
                        isOptionsExpanded.toggle()
                    }
                }
            } label: {
                SettingsRowLabel(title: "Options", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isOptionsExpanded {
                ReminderOptions(
                    hasDisplayNotch: hasDisplayNotch,
                    fullScreenReminder: fullScreenReminder,
                    intensiveReminder: intensiveReminder,
                    launchAtLogin: launchAtLogin,
                    onDisplayNotchChange: onDisplayNotchChange,
                    onFullScreenReminderChange: onFullScreenReminderChange,
                    onIntensiveReminderChange: onIntensiveReminderChange,
                    onLaunchAtLoginChange: onLaunchAtLoginChange
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var volumeRange: ClosedRange<Double> {
        unit == .metric ? 50...2_000 : 2...68
    }

    private var volumeStep: Double {
        unit == .metric ? 50 : 1
    }

    private var amountFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(unit == .metric ? 0 : 1))
    }
}

private struct MyInfoSettings: View {
    let age: Int
    let gender: ProfileGender
    let unit: VolumeUnit
    let onAgeChange: (Int) -> Void
    let onGenderChange: (ProfileGender) -> Void
    let onUnitChange: (VolumeUnit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(
                "Age: \(age)",
                value: Binding(
                    get: { age },
                    set: onAgeChange
                ),
                in: 1...120
            )

            Picker(
                "Gender",
                selection: Binding(
                    get: { gender },
                    set: onGenderChange
                )
            ) {
                ForEach(ProfileGender.allCases) { gender in
                    Text(gender.displayName)
                        .tag(gender)
                }
            }
            .pickerStyle(.segmented)

            Picker(
                "Units",
                selection: Binding(
                    get: { unit },
                    set: onUnitChange
                )
            ) {
                ForEach(VolumeUnit.allCases) { unit in
                    Text(unit.displayName)
                        .tag(unit)
                }
            }

            Text("Daily goal is a general estimate.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ReminderOptions: View {
    let hasDisplayNotch: Bool
    let fullScreenReminder: Bool
    let intensiveReminder: Bool
    let launchAtLogin: Bool
    let onDisplayNotchChange: (Bool) -> Void
    let onFullScreenReminderChange: (Bool) -> Void
    let onIntensiveReminderChange: (Bool) -> Void
    let onLaunchAtLoginChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Toggle(
                "Start at login",
                isOn: Binding(
                    get: { launchAtLogin },
                    set: onLaunchAtLoginChange
                )
            )

            Toggle(
                "Display has notch",
                isOn: Binding(
                    get: { hasDisplayNotch },
                    set: onDisplayNotchChange
                )
            )

            Toggle(
                "Full-screen shade",
                isOn: Binding(
                    get: { fullScreenReminder },
                    set: onFullScreenReminderChange
                )
            )
            .disabled(intensiveReminder)

            Toggle(
                "Intensive reminder",
                isOn: Binding(
                    get: { intensiveReminder },
                    set: onIntensiveReminderChange
                )
            )

            if intensiveReminder {
                Text("Reminders stay visible until you type the five displayed keys in order.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Accessibility access lets the reminder receive those keys while another app is active. It is used only while an intensive reminder is visible.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

        }
    }
}

private struct SettingsRowLabel: View {
    let title: LocalizedStringResource
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16)

            Text(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ContentView(model: HydrationModel(defaults: UserDefaults(suiteName: "Preview")!))
}
