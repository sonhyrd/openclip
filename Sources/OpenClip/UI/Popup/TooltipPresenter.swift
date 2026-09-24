// TooltipPresenter.swift
// OpenClip
//
// The shared hover-tooltip dwell state machine, extracted from the near-identical copies that
// lived in PopupView and the sub-bar content view. Owns only timing: a cold hover dwells
// `dwellNanoseconds` before the first show; while hot, switching targets shows immediately;
// after the target clears, `cooldownNanoseconds` elapse before the presenter goes cold again
// (so crossing a small gap between buttons doesn't re-dwell). Presentation of the tooltip itself
// is the caller's `show`/`hide` closures (routed to TooltipPanelController).
import Foundation

@MainActor
final class TooltipPresenter {
    static let dwellNanoseconds: UInt64 = 350_000_000
    static let cooldownNanoseconds: UInt64 = 300_000_000

    private var task: Task<Void, Never>?
    private var isHot = false

    /// Updates the tooltip for a newly hovered target. `text == nil` (no target, or a target
    /// without a tooltip) hides and starts the cooldown; otherwise shows after the dwell when
    /// cold, or immediately when hot.
    func update(text: String?, show: @escaping @MainActor () -> Void, hide: @escaping @MainActor () -> Void) {
        task?.cancel()
        guard text != nil else {
            hide()
            task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.cooldownNanoseconds)
                guard !Task.isCancelled else { return }
                self.task = nil
                self.isHot = false
            }
            return
        }
        if isHot {
            show()
        } else {
            task = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.dwellNanoseconds)
                guard !Task.isCancelled else { return }
                self.task = nil
                self.isHot = true
                show()
            }
        }
    }

    /// Tears down immediately (mode change, panel dismissal): cancels any pending dwell and
    /// drops the hot state so the next hover dwells from cold.
    func reset(hide: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = nil
        isHot = false
        hide()
    }
}
