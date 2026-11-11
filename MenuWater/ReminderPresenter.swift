import AppKit
import ApplicationServices
import Observation
import SwiftUI

@MainActor
final class ReminderPresenter {
    private struct Presentation {
        let id: UUID
        let pillPanel: NSPanel?
        let dimmingPanel: NSPanel?
        let previousApplication: NSRunningApplication?

        var panels: [NSPanel] {
            [dimmingPanel, pillPanel].compactMap { $0 }
        }
    }

    private enum Animation {
        static let openingDuration = 0.32
        static let closingDuration = 0.25
        static let verticalOffset: CGFloat = 6
    }

    private var presentation: Presentation?
    private var intensiveKeyMonitor: Any?
    private var globalKeyInterceptor: GlobalKeyInterceptor?

    func show(hasDisplayNotch: Bool, fullScreen: Bool, intensive: Bool) {
        dismissImmediately()

        let contentSize = NSSize(width: 250, height: 50)
        let screen = NSScreen.main
        let usesFullScreen = fullScreen || intensive
        let presentationID = UUID()
        let challenge = intensive ? IntensiveChallenge() : nil
        let dismissAction: () -> Void = { [weak self] in
            guard !intensive else {
                return
            }
            guard let self else {
                return
            }
            self.dismiss(presentationID: presentationID)
        }
        let pillPanel: NSPanel?
        if intensive {
            pillPanel = nil
        } else {
            let panel = makePanel(
                frame: NSRect(origin: .zero, size: contentSize),
                ignoresMouseEvents: false
            )
            panel.contentView = SwipeHostingView(
                rootView: WaterReminderPill(intensive: false, onDismiss: dismissAction),
                onSwipeUp: dismissAction
            )
            pillPanel = panel
        }

        let targetOrigin: NSPoint
        if let screen {
            let visibleFrame = screen.visibleFrame
            targetOrigin = NSPoint(
                x: visibleFrame.midX - contentSize.width / 2,
                y: visibleFrame.maxY - contentSize.height - (hasDisplayNotch ? 18 : 0)
            )
        } else {
            targetOrigin = .zero
        }

        pillPanel?.setFrameOrigin(
            NSPoint(
                x: targetOrigin.x,
                y: targetOrigin.y + Animation.verticalOffset
            )
        )
        pillPanel?.alphaValue = 0

        let dimmingPanel: NSPanel?
        if usesFullScreen, let screen {
            let panel = makePanel(
                frame: screen.frame,
                ignoresMouseEvents: true,
                canBecomeKey: intensive
            )
            panel.hasShadow = false
            if let challenge {
                panel.contentView = NSHostingView(
                    rootView: IntensiveDimmingOverlay(challenge: challenge)
                )
            } else {
                // A uniform shade needs no SwiftUI view graph or hosting layers.
                panel.backgroundColor = NSColor.black.withAlphaComponent(0.50)
            }
            panel.alphaValue = 0
            dimmingPanel = panel
        } else {
            dimmingPanel = nil
        }

        let previousApplication = intensive ? NSWorkspace.shared.frontmostApplication : nil
        presentation = Presentation(
            id: presentationID,
            pillPanel: pillPanel,
            dimmingPanel: dimmingPanel,
            previousApplication: previousApplication
        )
        if let challenge {
            let interceptor = GlobalKeyInterceptor { [weak self] character in
                guard challenge.accept(character) else {
                    return
                }
                self?.dismiss(presentationID: presentationID)
            }

            if interceptor.start() {
                globalKeyInterceptor = interceptor
            } else {
                startIntensiveKeyMonitoring(
                    presentationID: presentationID,
                    challenge: challenge
                )
            }
        }
        dimmingPanel?.orderFrontRegardless()
        pillPanel?.orderFrontRegardless()

        if intensive && globalKeyInterceptor == nil {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            dimmingPanel?.makeKeyAndOrderFront(nil)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Animation.openingDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimmingPanel?.animator().alphaValue = 1
            pillPanel?.animator().alphaValue = 1
            pillPanel?.animator().setFrameOrigin(targetOrigin)
        }
    }

    private func dismiss(presentationID: UUID) {
        guard let presentation, presentation.id == presentationID else {
            return
        }

        self.presentation = nil
        stopIntensiveKeyMonitoring()

        let pillPanel = presentation.pillPanel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Animation.closingDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for panel in presentation.panels {
                panel.animator().alphaValue = 0
            }
            if let pillPanel {
                pillPanel.animator().setFrameOrigin(
                    NSPoint(
                        x: pillPanel.frame.origin.x,
                        y: pillPanel.frame.origin.y + Animation.verticalOffset
                    )
                )
            }
        } completionHandler: {
            for panel in presentation.panels {
                panel.contentView = nil
                panel.close()
            }
            presentation.previousApplication?.activate()
        }
    }

    private func dismissImmediately() {
        guard let presentation else {
            return
        }

        self.presentation = nil
        stopIntensiveKeyMonitoring()
        for panel in presentation.panels {
            panel.contentView = nil
            panel.close()
        }
    }

    private func makePanel(
        frame: NSRect,
        ignoresMouseEvents: Bool,
        canBecomeKey: Bool = false
    ) -> NSPanel {
        let panel: NSPanel
        if canBecomeKey {
            panel = KeyableReminderPanel(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
        } else {
            panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        }

        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        return panel
    }

    private func startIntensiveKeyMonitoring(
        presentationID: UUID,
        challenge: IntensiveChallenge
    ) {
        intensiveKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if challenge.accept(event) {
                self?.dismiss(presentationID: presentationID)
            }

            return nil
        }
    }

    private func stopIntensiveKeyMonitoring() {
        globalKeyInterceptor?.stop()
        globalKeyInterceptor = nil

        guard let intensiveKeyMonitor else {
            return
        }

        NSEvent.removeMonitor(intensiveKeyMonitor)
        self.intensiveKeyMonitor = nil
    }

}

private final class KeyableReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class GlobalKeyInterceptor {
    private let onKeyDown: (String) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(onKeyDown: @escaping (String) -> Void) {
        self.onKeyDown = onKeyDown
    }

    func start() -> Bool {
        guard requestAccessibilityAccess() else {
            return false
        }

        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private nonisolated static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let interceptor = Unmanaged<GlobalKeyInterceptor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let eventTap = interceptor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let disallowedModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        let isRepeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard event.flags.intersection(disallowedModifiers).isEmpty, !isRepeating else {
            return nil
        }

        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &length,
            unicodeString: &characters
        )
        let input = String(utf16CodeUnits: characters, count: length)
        Task { @MainActor in
            interceptor.onKeyDown(input)
        }

        return nil
    }
}

@MainActor
@Observable
private final class IntensiveChallenge {
    struct Key: Identifiable {
        let id = UUID()
        let symbol: String
    }

    let keys: [Key]
    private(set) var enteredCount = 0

    init() {
        let availableKeys = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789").shuffled()
        keys = availableKeys.prefix(5).map { Key(symbol: String($0)) }
    }

    func accept(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !event.isARepeat,
              modifiers.intersection([.command, .control, .option]).isEmpty,
              let character = event.charactersIgnoringModifiers else {
            return false
        }

        return accept(character)
    }

    func accept(_ input: String) -> Bool {
        guard let character = input.uppercased().first else {
            return false
        }

        let typedKey = String(character)
        guard keys.indices.contains(enteredCount) else {
            return true
        }

        if typedKey == keys[enteredCount].symbol {
            enteredCount += 1
        } else {
            enteredCount = typedKey == keys[0].symbol ? 1 : 0
        }

        return enteredCount == keys.count
    }
}

private struct IntensiveDimmingOverlay: View {
    let challenge: IntensiveChallenge

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)

            VStack(spacing: 16) {
                Image(systemName: "drop.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(spacing: 5) {
                    Text("Time to drink water")
                        .font(.title2.weight(.semibold))

                    Text("Pause and take a drink")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Type these five keys in order to dismiss")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(Array(challenge.keys.enumerated()), id: \.element.id) { index, key in
                        IntensiveKeyCap(
                            symbol: key.symbol,
                            isEntered: index < challenge.enteredCount
                        )
                    }
                }

                Text("\(challenge.enteredCount) of 5 entered")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
        }
    }
}

private struct IntensiveKeyCap: View {
    let symbol: String
    let isEntered: Bool

    var body: some View {
        Text(symbol)
            .font(.headline.weight(.semibold))
            .frame(width: 38, height: 38)
            .background(
                isEntered ? .blue.opacity(0.65) : .white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isEntered ? .cyan.opacity(0.8) : .white.opacity(0.2), lineWidth: 1)
            }
            .animation(.smooth(duration: 0.18), value: isEntered)
    }
}

private final class SwipeHostingView<Content: View>: NSHostingView<Content> {
    private let onSwipeUp: () -> Void
    private var verticalScrollDistance = 0.0

    init(rootView: Content, onSwipeUp: @escaping () -> Void) {
        self.onSwipeUp = onSwipeUp
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) is unavailable")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began {
            verticalScrollDistance = 0
        }

        let directionMultiplier = event.isDirectionInvertedFromDevice ? -1.0 : 1.0
        verticalScrollDistance += event.scrollingDeltaY * directionMultiplier

        if verticalScrollDistance > 18 {
            verticalScrollDistance = 0
            onSwipeUp()
            return
        }

        if event.phase == .ended || event.phase == .cancelled {
            verticalScrollDistance = 0
        }
    }
}

private struct WaterReminderPill: View {
    let intensive: Bool
    let onDismiss: () -> Void

    @State private var progress = 0.0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Capsule()
                .fill(.regularMaterial)

            HStack(spacing: 8) {
                Image(systemName: "drop.fill")
                    .font(.body)
                    .foregroundStyle(.blue)

                Text("Time to drink water")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 14)
            .padding(.bottom, 2)

            if !intensive {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .blue.opacity(0.7),
                                    .cyan,
                                    .white.opacity(0.9),
                                    .blue
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .cyan.opacity(0.75), radius: 3, y: -1)
                        .shadow(color: .blue.opacity(0.45), radius: 6, y: -1)
                        .frame(width: geometry.size.width * progress, height: 2.5)
                        .frame(maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .contentShape(Capsule())
        .onTapGesture {
            if !intensive {
                onDismiss()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if !intensive && value.translation.height < -18 {
                        onDismiss()
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .task {
            guard !intensive else {
                return
            }

            await Task.yield()

            withAnimation(.linear(duration: 10)) {
                progress = 1
            }

            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else {
                return
            }
            onDismiss()
        }
    }

    private var accessibilityText: LocalizedStringResource {
        if intensive {
            "Time to drink water. Type the five displayed keys in order to dismiss."
        } else {
            "Time to drink water. This reminder closes in ten seconds."
        }
    }
}

#Preview {
    WaterReminderPill(intensive: false) {}
        .frame(width: 250, height: 50)
        .padding()
}
