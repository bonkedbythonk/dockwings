// The little door at the Dock end of the right wing that guest buddies come
// out of (Buddy.swift decides when). Drawn with shape layers: a dark doorway
// with a rounded top and a wooden leaf hinged on its left that swings open
// toward you. A soft shadow like the widgets' text; it fades in and out.
import AppKit
import QuartzCore

final class DoorLayer: CALayer {
    let width: CGFloat = 30
    let height: CGFloat = 46
    private let doorway = CAShapeLayer()
    private let leaf = CAShapeLayer()
    private let knob = CAShapeLayer()
    private let panels = CAShapeLayer()

    override init() {
        super.init()
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        anchorPoint = CGPoint(x: 0.5, y: 0)
        opacity = 0
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.45
        shadowRadius = 3
        shadowOffset = .zero
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 120
        sublayerTransform = perspective

        let shape = Self.archPath(CGRect(x: 0, y: 0, width: width, height: height))
        doorway.path = shape
        doorway.fillColor = NSColor(white: 0.06, alpha: 0.9).cgColor
        doorway.strokeColor = NSColor(red: 0.30, green: 0.19, blue: 0.10, alpha: 1).cgColor
        doorway.lineWidth = 2.5
        doorway.frame = bounds
        addSublayer(doorway)

        leaf.frame = bounds.insetBy(dx: 1.5, dy: 0).offsetBy(dx: 0, dy: 0)
        leaf.path = Self.archPath(CGRect(origin: .zero, size: leaf.bounds.size).insetBy(dx: 0, dy: 0))
        leaf.fillColor = NSColor(red: 0.56, green: 0.36, blue: 0.20, alpha: 1).cgColor
        leaf.strokeColor = NSColor(red: 0.36, green: 0.22, blue: 0.12, alpha: 1).cgColor
        leaf.lineWidth = 1
        // Hinged on its left edge.
        leaf.anchorPoint = CGPoint(x: 0, y: 0.5)
        leaf.position = CGPoint(x: 1.5, y: height / 2)
        addSublayer(leaf)

        let w = leaf.bounds.width
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: 5, y: height * 0.55, width: w - 10, height: height * 0.22), cornerWidth: 2, cornerHeight: 2)
        p.addRoundedRect(in: CGRect(x: 5, y: 5, width: w - 10, height: height * 0.4), cornerWidth: 2, cornerHeight: 2)
        panels.path = p
        panels.fillColor = nil
        panels.strokeColor = NSColor(red: 0.40, green: 0.25, blue: 0.13, alpha: 1).cgColor
        panels.lineWidth = 1
        panels.frame = leaf.bounds
        leaf.addSublayer(panels)

        knob.path = CGPath(ellipseIn: CGRect(x: w - 8, y: height * 0.47 - 2, width: 4, height: 4), transform: nil)
        knob.fillColor = NSColor(red: 0.95, green: 0.80, blue: 0.40, alpha: 1).cgColor
        knob.frame = leaf.bounds
        leaf.addSublayer(knob)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// A rectangle with a half-round top.
    private static func archPath(_ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let radius = r.width / 2
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY - radius), radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }

    /// Fades in at `point` (bottom middle), then swings open.
    func show(at point: CGPoint, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = point
        for l in [self, doorway, leaf, knob, panels] as [CALayer] { l.contentsScale = scale }
        leaf.transform = CATransform3DIdentity
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        opacity = 0.8
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.swing(open: true) }
    }

    func swing(open: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        leaf.transform = open ? CATransform3DMakeRotation(-1.3, 0, 1, 0) : CATransform3DIdentity
        CATransaction.commit()
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        opacity = 0
        CATransaction.commit()
    }
}
