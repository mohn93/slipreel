// packages/screen_recorder_macos/macos/Classes/CameraSelfViewPanel.swift
import AVFoundation
import Cocoa

/// A small, draggable, circular self-view window shown while recording so the
/// user can frame themselves. Fed by the shared AVCaptureSession's preview layer.
/// Reports its final center as a normalized point (0..1) in the main screen's
/// visible frame so the editor can seed the first camera region.
final class CameraSelfViewPanel: NSPanel {
  private let previewLayer: AVCaptureVideoPreviewLayer
  private static let diameter: CGFloat = 180

  init(session: AVCaptureSession) {
    self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
    let frame = NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
    super.init(contentRect: frame,
               styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // Keep this panel out of the screen recording entirely. The editor
    // re-renders the camera from the separate .camera.mov track, so a
    // captured self-view circle would double up with the rendered bubble.
    // sharingType .none is enforced by the window server, so it works even
    // though the panel is created after the capture stream starts (which is
    // why excludingApplications on the SCStream filter alone didn't catch it).
    // The panel stays visible to the user; it's just invisible to capture.
    sharingType = .none

    let host = NSView(frame: frame)
    host.wantsLayer = true
    host.layer?.cornerRadius = Self.diameter / 2
    host.layer?.masksToBounds = true
    previewLayer.frame = frame
    previewLayer.videoGravity = .resizeAspectFill
    host.layer?.addSublayer(previewLayer)
    contentView = host

    // Default position: bottom-right of the main screen's visible frame, inset.
    if let vf = NSScreen.main?.visibleFrame {
      let x = vf.maxX - Self.diameter - 32
      let y = vf.minY + 32
      setFrameOrigin(NSPoint(x: x, y: y))
    }
  }

  required init?(coder: NSCoder) {
    fatalError("CameraSelfViewPanel cannot be decoded from a nib/storyboard")
  }

  override var canBecomeKey: Bool { false }

  func show() { orderFrontRegardless() }

  /// The final center as a normalized (0..1) point in the main screen's visible
  /// frame, top-left origin (matches the editor's canvas coordinate space).
  func normalizedCenter() -> (x: Double, y: Double) {
    guard let vf = NSScreen.main?.visibleFrame else { return (0.82, 0.82) }
    let c = NSPoint(x: frame.midX, y: frame.midY)
    let nx = (Double(c.x) - Double(vf.minX)) / Double(vf.width)
    // Cocoa origin is bottom-left; flip Y to top-left for the editor.
    let nyBottom = (Double(c.y) - Double(vf.minY)) / Double(vf.height)
    let ny = 1.0 - nyBottom
    return (min(max(nx, 0), 1), min(max(ny, 0), 1))
  }

  func hide() { orderOut(nil) }
}
