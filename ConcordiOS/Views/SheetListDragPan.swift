import SwiftUI
import UIKit
import ObjectiveC

// MARK: - Sheet list-drag bridge (v0.2.119, FIX 3)
//
// A UIKit UIPanGestureRecognizer attached to the UIScrollView /
// UITableView underneath a sheet's list, driving the overlay's
// sheet-drag callbacks (onChanged = finger translation in points,
// onEnded = final translation + release velocity, pt/s, upward
// negative) — the same input shape the header drag already feeds
// the overlay, so the overlay handlers are unchanged in shape.
//
// WHY THIS, AND NOT THE v0.2.118 MECHANISM OR (A):
// - v0.2.118 used .simultaneousGesture(DragGesture) on the
//   scrolling container. It never delivers — for the Connections
//   List (UITableView-backed) that is a known SwiftUI weak point,
//   and the DNS ScrollView failed identically while the header
//   drag (same callbacks) works, so the mechanism, not the
//   wiring, is dead. It is removed, not tuned.
// - (A) — driving the sheet from the scroll position (anchor
//   minY via PreferenceKey) — was rejected for three reasons:
//   (1) it cannot see the finger lift, so there is no real
//   "ended" event and no release velocity, and the snap rule
//   needs velocity; synthesising "ended" from a minY-quiet
//   timer is fragile and the snap would lag the finger.
//   (2) it fails outright when the list is short or empty: a
//   list that cannot scroll never moves minY, so the sheet
//   could never grow by a list drag — and the DNS sheet is
//   often near-empty, the live feed often a handful of rows.
//   (3) it conflates scrolling with sheet growth: every upward
//   scroll at the short detent would grow the sheet even when
//   the user only wants to scroll, and a downward overscroll
//   (pull-to-refresh) is indistinguishable from a
//   sheet-shrink drag. Reading the touch avoids all three:
//   the recognizer knows began/changed/ended and velocity,
//   works with zero rows, and latches only on a drag that
//   starts at the top.
//
// HOW IT ATTACHES: the bridge is a zero-height first row of the
// list (it replaces the v0.2.118 anchor row, same slot, same
// zero-height layout), so its UIView is always inside the scroll
// view's content hierarchy. It walks up its superview chain to
// the first UIScrollView and attaches one pan recognizer to it.
// The coordinator is retained by the scroll view (associated
// object) so the recognizer's target/delegate stays alive even
// when the list unloads the first row (LazyVStack / cell reuse)
// — without that the recognizer would message a deallocated
// target. A second bridge instance finding the same scroll view
// (flat <-> grouped swap, row recreation) hands its callbacks
// to the existing coordinator instead of adding a second
// recognizer.
//
// DELIVERY PATH (trace): finger on a list row -> the scroll
// view's touch pipeline -> our UIPanGestureRecognizer (delegate
// allows simultaneous recognition with the scroll view's own
// pan recognizer, so the list still scrolls and pull-to-refresh
// still fires) -> Coordinator.handlePan -> onChanged/onEnded ->
// the overlay's sheetDragChanged/sheetDragEnded (ContentView).
// The list also scrolls a little while the sheet grows (no
// .scrollDisabled — that would break pull-to-refresh, same known
// limitation as v0.2.118); the sheet wins the height, the list
// keeps the scroll.

/// Zero-height bridge view: place as the first row/child of a
/// sheet's scrolling list. No-ops (never attaches) when the
/// callbacks are nil, so page mode is unaffected.
struct SheetListDragPan: UIViewRepresentable {
    /// Finger translation, points, upward negative. Called on
    /// every move while a sheet drag is latched.
    var onChanged: ((CGFloat) -> Void)?
    /// Final translation + release velocity (pt/s, upward
    /// negative). Called once, only if a drag latched.
    var onEnded: ((CGFloat, CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // The view is only a mount point for finding the scroll
        // view; it must never intercept touches itself.
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        context.coordinator.hostView = view
        context.coordinator.tryAttach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat, CGFloat) -> Void)?
        weak var hostView: UIView?

        private weak var scrollView: UIScrollView?
        private var attachAttempts = 0

        private enum Phase { case idle, forwarding, rejected }
        private var phase: Phase = .idle
        /// Whether the touch started with the list at the top,
        /// snapshotted when the recognizer begins: by the first
        /// .changed the list has already scrolled a few points,
        /// so a check there alone would miss the drag that
        /// starts exactly at the top.
        private var touchStartedAtTop = false
        /// Translation at the moment forwarding latched, so only
        /// the post-latch movement reaches the sheet (a drag
        /// that starts mid-list and reaches the top mid-drag
        /// must not pass its whole total as a sheet drag).
        private var startTranslation = CGPoint.zero

        /// The list is at its top when its content offset is at
        /// (or within `tolerance` of) the resting offset
        /// (-adjustedContentInset.top). The tolerance absorbs the
        /// few points the list scrolls between touch-down and
        /// recognition; a list scrolled any real distance down
        /// is never within it.
        private func isAtTop(_ scrollView: UIScrollView, tolerance: CGFloat) -> Bool {
            scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + tolerance
        }

        private func firstScrollView(above view: UIView) -> UIScrollView? {
            var current = view.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }

        func tryAttach() {
            guard onChanged != nil, onEnded != nil else { return }
            guard let hostView else { return }
            if let scrollView,
               let existing = objc_getAssociatedObject(scrollView, &sheetListDragPanCoordinatorKey) as? Coordinator,
               existing === self {
                return // already attached by this coordinator
            }
            guard let scrollView = firstScrollView(above: hostView) else {
                // Not in a scroll view's hierarchy yet (first
                // layout pass) — retry a few times on later
                // runloops, then give up silently: without a
                // scroll view there is nothing to attach to, and
                // the sheet still works via the header drag.
                attachAttempts += 1
                guard attachAttempts <= 20 else { return }
                DispatchQueue.main.async { [weak self] in self?.tryAttach() }
                return
            }
            self.scrollView = scrollView
            if let existing = objc_getAssociatedObject(scrollView, &sheetListDragPanCoordinatorKey) as? Coordinator,
               existing !== self {
                // Another bridge instance already owns this scroll
                // view (List cell reuse, flat <-> grouped swap,
                // LazyVStack recreating the first row): hand it
                // the current callbacks and let it drive.
                existing.onChanged = onChanged
                existing.onEnded = onEnded
                return
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            // Never cancel touches in the scroll view (row taps,
            // buttons) and never delay them: this recognizer only
            // observes, the scroll view keeps the touch.
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            // One finger, like the header DragGesture: a second
            // finger must not hijack the sheet drag.
            pan.maximumNumberOfTouches = 1
            scrollView.addGestureRecognizer(pan)
            objc_setAssociatedObject(scrollView, &sheetListDragPanCoordinatorKey, self,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if let scrollView { touchStartedAtTop = isAtTop(scrollView, tolerance: 8) }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // The scroll view's own pan recognizer MUST keep
            // receiving the touch: the list scrolls a little
            // while the sheet grows, and pull-to-refresh is
            // driven by that recognizer. Without this the UIKit
            // pan would win the touch and the list would stop
            // scrolling entirely.
            true
        }

        // MARK: Pan handling

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let scrollView, let onChanged, let onEnded else { return }
            switch recognizer.state {
            case .began:
                phase = .idle
                startTranslation = .zero
            case .changed:
                // Window coordinates, NOT the scroll view's: the
                // scroll view's coordinate system moves with its
                // content, so translation(in: scrollView) would
                // under-report (near zero) while the list tracks
                // the finger 1:1. Window coordinates are pure
                // finger displacement on screen — exactly what
                // the overlay's sheetDragChanged expects, same as
                // the header DragGesture's translation.
                let translation = recognizer.translation(in: nil)
                if phase == .idle {
                    // Horizontal-first: a row swipe-to-disconnect
                    // or the horizontal filter strip — never a
                    // sheet drag. Rejected for the rest of this
                    // touch.
                    if abs(translation.x) >= 8, abs(translation.x) > abs(translation.y) {
                        phase = .rejected
                        return
                    }
                    guard abs(translation.y) >= 8, abs(translation.y) >= abs(translation.x) else { return }
                    // Latch only if the touch started at the top,
                    // or the list has since been scrolled back to
                    // (near) the top mid-drag. The 32pt tolerance
                    // absorbs the scroll that happened before
                    // this first vertical .changed.
                    guard touchStartedAtTop || isAtTop(scrollView, tolerance: 32) else { return }
                    phase = .forwarding
                    startTranslation = translation
                }
                guard phase == .forwarding else { return }
                onChanged(translation.y - startTranslation.y)
            case .ended, .cancelled, .failed:
                if phase == .forwarding {
                    let translation = recognizer.translation(in: nil)
                    onEnded(translation.y - startTranslation.y, recognizer.velocity(in: nil).y)
                }
                phase = .idle
            default:
                break
            }
        }
    }
}

/// Associated-object key retaining the bridge coordinator on its
/// scroll view (see SheetListDragPan).
private var sheetListDragPanCoordinatorKey: UInt8 = 0
