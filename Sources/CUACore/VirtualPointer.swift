import AppKit
import ApplicationServices

/// The pointer is a *presentation*, never an input source. Keeping it separate
/// from ActionBridge prevents visualization from changing delivery semantics.
public enum VirtualPointerEffect {
    case hover
    case click
    case drag
}

/// A small, click-through panel above the target window. It is only ordered on
/// screen while that window's app is frontmost; `order(_:relativeTo:)` affects
/// our panel, not the target window, and never activates either application.
public final class VirtualPointer {
    private let panel: NSPanel
    private let pointerView = VirtualPointerView()
    private var pid: pid_t?
    private var point = CGPoint.zero
    private var targetFrame = CGRect.zero
    private var targetWindow = 0
    private var activationObserver: NSObjectProtocol?


    public init() {
        _ = NSApplication.shared
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // A cross-process panel must use a higher level to composite above the
        // target app's window. render() orders it relative to that window and
        // hides it whenever that app is not frontmost.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = pointerView
        panel.isReleasedWhenClosed = false
        panel.orderOut(nil)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.render() }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Remember the target without inventing a pointer position on a state read.
    public func track(pid: pid_t, frame: CGRect?, windowNumber: CGWindowID?) {
        performOnMain {
            self.pid = pid
            self.targetFrame = frame ?? .zero
            self.targetWindow = Int(windowNumber ?? 0)
            self.render()
        }
    }

    /// Direct updates used at each step of an actual drag. The main thread is
    /// free while MCP work runs on its worker, so AppKit can draw every step.
    public func update(pid: pid_t, point: CGPoint, frame: CGRect?, windowNumber: CGWindowID?,
                       effect: VirtualPointerEffect) {
        performOnMain {
            self.pid = pid
            self.point = point
            self.targetFrame = frame ?? self.targetFrame
            self.targetWindow = Int(windowNumber ?? 0)
            self.pointerView.effect = effect
            self.render()
        }
    }

    /// Visually travel to the destination, rather than teleporting, for actions
    /// whose underlying delivery is a single AXPress or AXValue write.
    public func move(pid: pid_t, to destination: CGPoint, frame: CGRect?, windowNumber: CGWindowID?,
                     effect: VirtualPointerEffect = .hover) async {
        let start = await MainActor.run { self.pid == pid ? self.point : destination }
        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let eased = 1 - pow(1 - t, 3)
            let p = CGPoint(x: start.x + (destination.x - start.x) * eased,
                            y: start.y + (destination.y - start.y) * eased)
            await MainActor.run {
                self.pid = pid
                self.point = p
                self.targetFrame = frame ?? self.targetFrame
                self.targetWindow = Int(windowNumber ?? 0)
                self.pointerView.effect = effect
                self.render()
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    public func flash(_ effect: VirtualPointerEffect) async {
        await MainActor.run {
            self.pointerView.effect = effect
            self.render()
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run {
            self.pointerView.effect = .hover
            self.render()
        }
    }

    /// Remove the pointer without forgetting the target, so the next tracked
    /// action can put it back if the user returns to that app.
    public func hide() {
        performOnMain { self.panel.orderOut(nil) }
    }

    private func performOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() }
        else { DispatchQueue.main.async(execute: body) }
    }

    /// The visibility rule, as a pure function so it can be asserted directly
    /// without ordering a window or activating anything.
    ///
    /// The pointer is shown only when the target app is the one the user is
    /// already looking at. It never causes that: `frontmostPID` is read, never
    /// written, and the panel is a non-activating NSPanel that cannot become key.
    public static func shouldShow(targetPID: pid_t, frontmostPID: pid_t?,
                                  targetWindow: Int, targetFrame: CGRect,
                                  point: CGPoint) -> Bool {
        guard frontmostPID == targetPID, targetWindow > 0, targetFrame.width > 0 else { return false }
        return targetFrame.insetBy(dx: -24, dy: -24).contains(point)
    }

    private func render() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.render() }
            return
        }
        guard let pid,
              let primaryHeight = NSScreen.screens.first?.frame.maxY,
              Self.shouldShow(targetPID: pid,
                              frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                              targetWindow: targetWindow,
                              targetFrame: targetFrame,
                              point: point) else {
            panel.orderOut(nil)
            return
        }
        // CoreGraphics uses a top-left primary-screen origin; AppKit bottom-left.
        let y = primaryHeight - point.y
        panel.setFrame(CGRect(x: point.x - 5, y: y - 35, width: 40, height: 40), display: true)
        pointerView.needsDisplay = true
        panel.order(.above, relativeTo: targetWindow)
    }
}

private final class VirtualPointerView: NSView {
    var effect: VirtualPointerEffect = .hover {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(calibratedRed: 0.08, green: 0.72, blue: 1.0, alpha: 0.96)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 5, y: 35))
        arrow.line(to: NSPoint(x: 5, y: 12))
        arrow.line(to: NSPoint(x: 12, y: 18))
        arrow.line(to: NSPoint(x: 17, y: 8))
        arrow.line(to: NSPoint(x: 23, y: 11))
        arrow.line(to: NSPoint(x: 18, y: 21))
        arrow.line(to: NSPoint(x: 28, y: 21))
        arrow.close()
        arrow.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.95).setStroke()
        arrow.lineWidth = 3.5
        arrow.stroke()
        color.setFill()
        arrow.fill()
        NSColor(calibratedWhite: 0.05, alpha: 0.9).setStroke()
        arrow.lineWidth = 1.2
        arrow.stroke()

        if effect != .hover {
            let ring = NSBezierPath(ovalIn: CGRect(x: 1, y: 24, width: effect == .click ? 17 : 13,
                                                    height: effect == .click ? 17 : 13))
            color.setStroke()
            ring.lineWidth = effect == .click ? 3 : 2
            ring.stroke()
        }
    }
}
