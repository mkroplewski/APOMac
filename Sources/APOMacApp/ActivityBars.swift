import AppKit
import QuartzCore
import SwiftUI

/// A small "now playing" bar animation.
///
/// It is built from Core Animation layers with repeating animations, which
/// the window server runs on its own: the app does no per-frame work. (A
/// SwiftUI `symbolEffect` re-evaluates the view graph every frame on the main
/// thread, which cost ~20% CPU.) The frame rate is capped because a 14 pt
/// indicator does not need 120 Hz.
struct ActivityBars: NSViewRepresentable {
    var isAnimating = true
    @Environment(\.backgroundProminence) private var backgroundProminence

    func makeNSView(context: Context) -> ActivityBarsView {
        ActivityBarsView()
    }

    func updateNSView(_ view: ActivityBarsView, context: Context) {
        // Selected sidebar rows have an accent background; draw white on them.
        view.usesProminentColor = backgroundProminence == .increased
        view.isAnimating = isAnimating
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ActivityBarsView, context: Context) -> CGSize? {
        CGSize(width: 14, height: 12)
    }
}

final class ActivityBarsView: NSView {
    private let bars: [CALayer] = (0..<3).map { _ in CALayer() }
    private static let keyframes: [[CGFloat]] = [
        [0.35, 1.0, 0.55, 0.85, 0.35],
        [0.9, 0.4, 1.0, 0.5, 0.9],
        [0.5, 0.8, 0.3, 1.0, 0.5]
    ]
    private static let durations: [CFTimeInterval] = [1.1, 0.9, 1.3]

    var usesProminentColor = false {
        didSet { if usesProminentColor != oldValue { updateColors() } }
    }

    var isAnimating = true {
        didSet { if isAnimating != oldValue { updateAnimations() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for bar in bars {
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.cornerRadius = 1.25
            layer?.addSublayer(bar)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 12) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width: CGFloat = 2.5
        let gap = (bounds.width - width * CGFloat(bars.count)) / CGFloat(bars.count - 1)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: 0)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (usesProminentColor ? NSColor.white : NSColor.controlAccentColor).cgColor
            for bar in bars { bar.backgroundColor = color }
        }
    }

    private func updateAnimations() {
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            guard isAnimating, window != nil else {
                bar.transform = CATransform3DMakeScale(1, 0.5, 1)
                continue
            }
            let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
            animation.values = Self.keyframes[index]
            animation.duration = Self.durations[index]
            animation.repeatCount = .infinity
            animation.calculationMode = .cubic
            animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
            bar.add(animation, forKey: "level")
        }
    }
}
