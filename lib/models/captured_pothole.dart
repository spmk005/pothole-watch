import 'dart:ui';

/// Holds data for a single pothole capture during a live detection session.
/// The image is saved to a temp file; the bounding box is in normalized
/// (0-1) coordinates from YOLO's `normalizedBox`.
class CapturedPothole {
  final String imagePath;
  final Rect normalizedBox;
  final double lat;
  final double lng;
  final double confidence;
  String? supabaseId;

  CapturedPothole({
    required this.imagePath,
    required this.normalizedBox,
    required this.lat,
    required this.lng,
    required this.confidence,
    this.supabaseId,
  });
}

/// Result returned after MiDaS depth severity analysis.
class SeverityResult {
  final CapturedPothole capture;
  final String severity; // 'Low', 'Medium', 'Severe'
  final double depthDropoff;

  SeverityResult({
    required this.capture,
    required this.severity,
    required this.depthDropoff,
  });
}
