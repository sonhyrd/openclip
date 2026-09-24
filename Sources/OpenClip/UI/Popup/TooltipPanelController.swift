// TooltipPanelController.swift
// OpenClip
//
// Owns the TooltipPanel + its hosting view and the measure → place → show cycle for hover
// tooltips. The single tooltip surface for both the main bar and the sub-bar: callers pass the
// hovered button's screen frame plus the rects to avoid (the sibling panel), TooltipPlacer picks
// the edge and origin, and the panel renders unclipped in screen space. Shared singleton — the
// tooltip is transient chrome with exactly one instance alive at a time, mirroring
// PopupHoverState.shared; both popup controllers hide() it on teardown.
import AppKit
import SwiftUI
import Core

@MainActor
public final class TooltipPanelController {
    public static let shared = TooltipPanelController()

    /// Transparent ring (pt) around the tooltip bubble inside the panel frame so its SwiftUI
    /// drop shadow (radius 3, y 1.5) renders instead of being clipped at the window edge.
    static let shadowInset: CGFloat = 6

    private let panel: TooltipPanel
    private let hostingView: TooltipHostingView
    public private(set) var isShowing = false
    /// The tooltip panel's current frame (screen coords). Internal for tests.
    var panelFrame: NSRect { panel.frame }

    public init(panel: TooltipPanel = TooltipPanel()) {
        self.panel = panel
        self.hostingView = TooltipHostingView(
            rootView: PopupTooltipView(text: "")
        )
        let container = TooltipContainerView(frame: .zero)
        container.addSubview(hostingView)
        self.panel.contentView = container
    }

    /// Measures, places, and shows the tooltip for a hovered target.
    ///
    /// - Parameters:
    ///   - targetScreenFrame: the hovered button's frame in screen coordinates.
    ///   - avoidanceRects: screen rects the tooltip must not intersect (the sibling bar panel).
    ///   - maxWidth: cap on the tooltip bubble width (mirrors the old in-panel clamp).
    public func show(
        text: String,
        targetScreenFrame: CGRect,
        avoidanceRects: [CGRect] = [],
        cursorLocation: CGPoint? = nil,
        effectiveTheme: String = "glass",
        isDark: Bool = true,
        maxWidth: CGFloat? = nil
    ) {
        guard !text.isEmpty, targetScreenFrame.width > 0, targetScreenFrame.height > 0 else {
            hide()
            return
        }

        let cappedWidth = maxWidth.map { max(40, $0) }
        hostingView.rootView = PopupTooltipView(
            text: text,
            effectiveTheme: effectiveTheme,
            isDark: isDark,
            maxWidth: cappedWidth
        )
        hostingView.layoutSubtreeIfNeeded()
        let fit = hostingView.fittingSize
        guard fit.width > 0, fit.height > 0 else { return }

        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: targetScreenFrame.midX, y: targetScreenFrame.midY)) }
            ?? NSScreen.screens.first { $0.frame.intersects(targetScreenFrame) }
            ?? NSScreen.main
        let screenBounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)

        let placement = TooltipPlacer.place(
            targetScreenFrame: targetScreenFrame,
            tooltipSize: fit,
            screenBounds: screenBounds,
            avoidanceRects: avoidanceRects,
            cursorLocation: cursorLocation ?? NSEvent.mouseLocation
        )

        hostingView.frame = NSRect(x: Self.shadowInset, y: Self.shadowInset, width: fit.width, height: fit.height)
        panel.contentView?.frame = NSRect(
            origin: .zero,
            size: NSSize(width: fit.width + Self.shadowInset * 2, height: fit.height + Self.shadowInset * 2)
        )
        panel.setFrame(
            NSRect(x: placement.origin.x - Self.shadowInset,
                   y: placement.origin.y - Self.shadowInset,
                   width: fit.width + Self.shadowInset * 2,
                   height: fit.height + Self.shadowInset * 2),
            display: true
        )

        isShowing = true
        if panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    public func hide() {
        guard isShowing || panel.isVisible else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show() racing the fade-out flips isShowing back and animates alpha to 1;
                // only tear the window down when the hide is still the latest intent.
                guard let self, !self.isShowing, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }
}
