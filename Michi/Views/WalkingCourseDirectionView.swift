import MapKit
import UIKit

/// Only the three handles intercept touches. Everything else, including the
/// sector interior, passes through to MapKit's existing pan/pinch gestures.
final class WalkingCourseDirectionView: UIView {
    private weak var map: MKMapView?
    private var origin = CLLocationCoordinate2D()
    private var direction = WalkingCourseGeometry.Direction()
    private var radiusMeters = 360.0
    private var handleFill = UIColor.white
    private var japanese = true
    private var dragging: Int?
    private var initialDirection = WalkingCourseGeometry.Direction()
    private var previousDragBearing = 0.0
    private var dragRotation = 0.0
    var onChange: ((Double, Double) -> Void)?
    private var adjustableHandles: [CourseDirectionAccessibilityHandle] = []

    init(map: MKMapView) {
        self.map = map
        super.init(frame: map.bounds)
        backgroundColor = .clear
        isOpaque = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let handlePan = UIPanGestureRecognizer(target: self, action: #selector(dragHandle(_:)))
        addGestureRecognizer(handlePan)
        // MapKit's ancestor pan must not win a drag that began on a handle.
        // Elsewhere this view fails hit-testing, so map gestures start normally.
        for recognizer in map.gestureRecognizers ?? [] where recognizer is UIPanGestureRecognizer {
            recognizer.require(toFail: handlePan)
        }
        isAccessibilityElement = false
        for index in 0..<3 {
            let element = CourseDirectionAccessibilityHandle(accessibilityContainer: self)
            element.accessibilityTraits = .adjustable
            element.adjust = { [weak self] delta in
                guard let self else { return }
                if index == 0 {
                    direction = .init(bearing: direction.bearing + delta * 15, opening: direction.opening)
                } else {
                    direction = .init(bearing: direction.bearing, opening: direction.opening + delta * 10)
                }
                onChange?(direction.bearing, direction.opening)
                refresh()
            }
            adjustableHandles.append(element)
        }
        accessibilityElements = adjustableHandles
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(origin: CLLocationCoordinate2D, direction: WalkingCourseGeometry.Direction,
                   radiusMeters: Double, dark: Bool, japanese: Bool, onChange: ((Double, Double) -> Void)?) {
        self.origin = origin
        if dragging == nil { self.direction = direction }
        self.radiusMeters = radiusMeters
        self.japanese = japanese
        handleFill = dark ? UIColor(red: 0.06, green: 0.11, blue: 0.16, alpha: 1) : .white
        self.onChange = onChange
        refresh()
    }

    private struct Geometry {
        let center: CGPoint
        let arc: [CGPoint]
        // First handle rotates; left/right handles change the center angle.
        let handles: [CGPoint]
        let rawSides: [CGPoint]
    }

    private func geometry() -> Geometry? {
        guard let map, bounds.width > 0, CLLocationCoordinate2DIsValid(origin) else { return nil }
        let center = map.convert(origin, toPointTo: self)
        let edge = WalkingCourseGeometry.waypoint(from: origin, meters: radiusMeters, bearing: direction.bearing * .pi / 180)
        let edgePoint = map.convert(edge, toPointTo: self)
        let size = hypot(edgePoint.x - center.x, edgePoint.y - center.y)
        guard size.isFinite, size > 0.001 else { return nil }
        // The sector itself always uses geographic distance. Only the control
        // handles have a screen-space limit so zooming cannot make them unusable.
        let handleMeters = radiusMeters * Double(min(145, max(90, size)) / size)
        func point(_ bearing: Double, meters: Double, fraction: Double = 1) -> CGPoint {
            let coordinate = WalkingCourseGeometry.waypoint(from: origin, meters: meters * fraction,
                bearing: bearing * .pi / 180)
            return map.convert(coordinate, toPointTo: self)
        }
        let arc = (0...30).map { index in
            point(direction.bearing - direction.opening / 2 + direction.opening * Double(index) / 30, meters: radiusMeters)
        }
        let tip = point(direction.bearing, meters: handleMeters)
        let rawSides = [point(direction.bearing - direction.opening / 2, meters: handleMeters, fraction: 0.76),
                        point(direction.bearing + direction.opening / 2, meters: handleMeters, fraction: 0.76)]
        var sides = rawSides
        let separation = hypot(sides[1].x - sides[0].x, sides[1].y - sides[0].y)
        if separation < 34 {
            let dx = tip.x - center.x, dy = tip.y - center.y
            let length = max(1, hypot(dx, dy))
            let push = (34 - separation) / 2
            sides[0].x += dy / length * push; sides[0].y -= dx / length * push
            sides[1].x -= dy / length * push; sides[1].y += dx / length * push
        }
        return Geometry(center: center, arc: arc, handles: [tip] + sides, rawSides: rawSides)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, let geometry = geometry() else { return false }
        return geometry.handles.contains { hypot($0.x - point.x, $0.y - point.y) <= 24 }
    }

    @objc private func dragHandle(_ gesture: UIPanGestureRecognizer) {
        guard let map else { return }
        let point = gesture.location(in: self)
        if gesture.state == .began {
            guard let geometry = geometry() else { return }
            dragging = geometry.handles.indices.min {
                hypot(geometry.handles[$0].x - point.x, geometry.handles[$0].y - point.y)
                    < hypot(geometry.handles[$1].x - point.x, geometry.handles[$1].y - point.y)
            }
            initialDirection = direction
            previousDragBearing = WalkingCourseGeometry.bearing(from: origin, to: map.convert(point, toCoordinateFrom: self))
            dragRotation = 0
        }
        guard let dragging else { return }
        if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
            let coordinate = map.convert(point, toCoordinateFrom: self)
            let bearing = WalkingCourseGeometry.bearing(from: origin, to: coordinate)
            if dragging == 0 { direction = .init(bearing: bearing, opening: initialDirection.opening) }
            else {
                // Accumulate signed motion across the north/360 seam, including
                // when the two width handles are separated for touch targets.
                dragRotation += WalkingCourseGeometry.Direction.delta(bearing, previousDragBearing)
                previousDragBearing = bearing
                let opening = initialDirection.opening + dragRotation * (dragging == 1 ? -2 : 2)
                direction = .init(bearing: initialDirection.bearing, opening: opening)
            }
            refresh()
        }
        if gesture.state == .ended {
            self.dragging = nil
            onChange?(direction.bearing, direction.opening)
        } else if gesture.state == .cancelled || gesture.state == .failed {
            self.dragging = nil; direction = initialDirection; refresh()
        }
    }

    func refresh() {
        setNeedsDisplay()
        guard let geometry = geometry() else { return }
        for index in adjustableHandles.indices {
            let element = adjustableHandles[index]
            element.accessibilityLabel = index == 0 ? (japanese ? "コースの方角" : "Route direction")
                : (japanese ? "扇形の開き" : "Sector width")
            element.accessibilityValue = "\(Int((index == 0 ? direction.bearing : direction.opening).rounded()))°"
            element.accessibilityFrameInContainerSpace = CGRect(x: geometry.handles[index].x - 24,
                y: geometry.handles[index].y - 24, width: 48, height: 48)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let geometry = geometry() else { return }
        let color = WalkingCourseStyle.uiAccent
        context.saveGState(); defer { context.restoreGState() }
        let sector = UIBezierPath()
        sector.move(to: direction.opening == 360 ? geometry.arc[0] : geometry.center)
        for point in geometry.arc { sector.addLine(to: point) }
        sector.close()
        color.withAlphaComponent(0.13).setFill(); sector.fill()
        color.withAlphaComponent(0.7).setStroke(); sector.lineWidth = 1.2; sector.stroke()
        context.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1); context.setLineDash(phase: 0, lengths: [3, 4])
        context.move(to: geometry.center); context.addLine(to: geometry.handles[0]); context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        for index in 0..<2 {
            context.move(to: geometry.rawSides[index]); context.addLine(to: geometry.handles[index + 1]); context.strokePath()
        }
        for (index, point) in geometry.handles.enumerated() {
            let radius: CGFloat = index == 0 ? 17 : 11
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.15).cgColor)
            let circle = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            handleFill.setFill(); circle.fill()
            context.setShadow(offset: .zero, blur: 0)
            color.setStroke(); circle.lineWidth = 1.5; circle.stroke()
            if index == 0 {
                UIImage(systemName: "arrow.triangle.2.circlepath")?.withTintColor(color, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
            } else {
                color.setFill(); UIBezierPath(ovalIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
            }
        }
    }
}

private final class CourseDirectionAccessibilityHandle: UIAccessibilityElement {
    var adjust: ((Double) -> Void)?
    override func accessibilityIncrement() { adjust?(1) }
    override func accessibilityDecrement() { adjust?(-1) }
}
