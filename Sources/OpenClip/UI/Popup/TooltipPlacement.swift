// TooltipPlacement.swift
// OpenClip
//
// Pure placement solver for the floating tooltip window. Decides which edge of the hovered
// button (above or below) the tooltip renders on and where, in screen coordinates, so it never
// intersects an avoidance rect (the expanded sub-bar, the main bar panel) and never leaves the
// screen's visible frame. Presentation concern — lives in the App target next to PopupMetrics.
import CoreGraphics

public enum TooltipPlacementEdge: String, Sendable {
    case above
    case below
}

public struct TooltipPlacement: Equatable, Sendable {
    public let edge: TooltipPlacementEdge
    /// Origin of the tooltip's content rect in screen coordinates (y-up, bottom-left origin).
    public let origin: CGPoint
    public let size: CGSize

    public var frame: CGRect {
        CGRect(origin: origin, size: size)
    }
}

public enum TooltipPlacer {
    /// Visual gap between the hovered button and the tooltip.
    public static let gap: CGFloat = 4

    /// Chooses the tooltip rect for a hovered target.
    ///
    /// - Parameters:
    ///   - targetScreenFrame: the hovered button's frame in screen coordinates.
    ///   - tooltipSize: the measured tooltip content size.
    ///   - screenBounds: the visible frame of the screen the target lives on.
    ///   - avoidanceRects: screen rects the tooltip must not intersect (e.g. the expanded
    ///     sub-bar's panel frame when hovering the main bar, and vice versa).
    ///   - cursorLocation: the current pointer location in screen coordinates; a candidate that
    ///     would cover the cursor is demoted so the tooltip never hides the pointer.
    ///   - padding: minimum inset from the screen's visible-frame edges.
    public static func place(
        targetScreenFrame target: CGRect,
        tooltipSize: CGSize,
        screenBounds: CGRect,
        avoidanceRects: [CGRect] = [],
        cursorLocation: CGPoint? = nil,
        padding: CGFloat = PopupMetrics.popupPadding
    ) -> TooltipPlacement {
        let above = candidate(edge: .above, target: target, size: tooltipSize, screenBounds: screenBounds, padding: padding)
        let below = candidate(edge: .below, target: target, size: tooltipSize, screenBounds: screenBounds, padding: padding)

        let aboveScore = score(above, screenBounds: screenBounds, avoidanceRects: avoidanceRects, cursorLocation: cursorLocation)
        let belowScore = score(below, screenBounds: screenBounds, avoidanceRects: avoidanceRects, cursorLocation: cursorLocation)

        // Prefer above on ties — the established orientation.
        let chosen = belowScore > aboveScore ? below : above
        return clampToScreen(chosen, screenBounds: screenBounds, padding: padding)
    }

    private static func candidate(
        edge: TooltipPlacementEdge,
        target: CGRect,
        size: CGSize,
        screenBounds: CGRect,
        padding: CGFloat
    ) -> TooltipPlacement {
        let originY: CGFloat
        switch edge {
        case .above:
            originY = target.maxY + gap
        case .below:
            originY = target.minY - gap - size.height
        }
        let minX = screenBounds.minX + padding
        let maxX = max(minX, screenBounds.maxX - padding - size.width)
        let originX = min(max(target.midX - size.width / 2, minX), maxX)
        return TooltipPlacement(edge: edge, origin: CGPoint(x: originX, y: originY), size: size)
    }

    /// Higher is better. A candidate loses points for leaving the screen, intersecting an
    /// avoidance rect (proportionally to the overlapped area), or covering the cursor.
    private static func score(
        _ placement: TooltipPlacement,
        screenBounds: CGRect,
        avoidanceRects: [CGRect],
        cursorLocation: CGPoint?
    ) -> CGFloat {
        let frame = placement.frame
        var result: CGFloat = 0

        if !screenBounds.contains(frame) {
            let clipped = frame.intersection(screenBounds)
            let visibleFraction = clipped.isNull ? 0 : (clipped.width * clipped.height) / max(1, frame.width * frame.height)
            result -= 1000 * (1 - visibleFraction)
        }

        for rect in avoidanceRects {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let overlapFraction = (overlap.width * overlap.height) / max(1, frame.width * frame.height)
            result -= 100 * overlapFraction
        }

        if let cursorLocation, frame.insetBy(dx: -2, dy: -2).contains(cursorLocation) {
            result -= 50
        }

        return result
    }

    /// Last-resort containment: if even the chosen edge cannot fit on screen (tiny screens,
    /// huge tooltips), slide the rect back inside the visible frame.
    private static func clampToScreen(_ placement: TooltipPlacement, screenBounds: CGRect, padding: CGFloat) -> TooltipPlacement {
        var origin = placement.origin
        let minX = screenBounds.minX + padding
        let maxX = max(minX, screenBounds.maxX - padding - placement.size.width)
        let minY = screenBounds.minY + padding
        let maxY = max(minY, screenBounds.maxY - padding - placement.size.height)
        origin.x = min(max(origin.x, minX), maxX)
        origin.y = min(max(origin.y, minY), maxY)
        return TooltipPlacement(edge: placement.edge, origin: origin, size: placement.size)
    }
}
