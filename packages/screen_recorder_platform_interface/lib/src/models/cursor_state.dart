/// Stock cursor types macOS exposes via NSCursor and the equivalents
/// on other platforms. Captured natively per recorded sample so the
/// editor can render the right glyph during playback (e.g. an I-beam
/// over a text field, a pointing hand over a link).
///
/// Order is the wire format — the native side and the editor both
/// pass these by name string. Adding new values is backwards-safe;
/// reordering or removing values would break replay of old
/// recordings, so don't.
enum CursorState {
  /// Default arrow pointer. Used as the fallback whenever the native
  /// side can't identify the active cursor (custom app cursors, etc).
  arrow,

  /// Vertical I-beam shown over editable text.
  iBeam,

  /// Hand with pointing index finger. Used over links / clickable
  /// targets.
  pointingHand,

  /// Crosshair shown for precision selection (e.g. screenshot tool).
  crosshair,

  /// Vertical double-arrow — north/south resize.
  resizeNS,

  /// Horizontal double-arrow — east/west resize.
  resizeEW,

  /// Diagonal double-arrow — northeast/southwest resize.
  resizeNESW,

  /// Diagonal double-arrow — northwest/southeast resize.
  resizeNWSE,

  /// Forbidden (slashed circle) — drop target rejects the operation.
  notAllowed,

  /// Open hand — drag may begin.
  openHand,

  /// Closed (grabbing) hand — actively dragging.
  closedHand,
}

extension CursorStateWire on CursorState {
  /// String wire form used in JSON / event-channel maps.
  String get wireName {
    switch (this) {
      case CursorState.arrow:
        return 'arrow';
      case CursorState.iBeam:
        return 'iBeam';
      case CursorState.pointingHand:
        return 'pointingHand';
      case CursorState.crosshair:
        return 'crosshair';
      case CursorState.resizeNS:
        return 'resizeNS';
      case CursorState.resizeEW:
        return 'resizeEW';
      case CursorState.resizeNESW:
        return 'resizeNESW';
      case CursorState.resizeNWSE:
        return 'resizeNWSE';
      case CursorState.notAllowed:
        return 'notAllowed';
      case CursorState.openHand:
        return 'openHand';
      case CursorState.closedHand:
        return 'closedHand';
    }
  }

  /// Inverse of [wireName]. Returns [CursorState.arrow] for null /
  /// unknown values so legacy recordings (which had no state field)
  /// load cleanly with arrow as the implicit default.
  static CursorState fromWireName(String? name) {
    switch (name) {
      case 'iBeam':
        return CursorState.iBeam;
      case 'pointingHand':
        return CursorState.pointingHand;
      case 'crosshair':
        return CursorState.crosshair;
      case 'resizeNS':
        return CursorState.resizeNS;
      case 'resizeEW':
        return CursorState.resizeEW;
      case 'resizeNESW':
        return CursorState.resizeNESW;
      case 'resizeNWSE':
        return CursorState.resizeNWSE;
      case 'notAllowed':
        return CursorState.notAllowed;
      case 'openHand':
        return CursorState.openHand;
      case 'closedHand':
        return CursorState.closedHand;
      case 'arrow':
      default:
        return CursorState.arrow;
    }
  }
}
