import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Data class emitted when a pothole impact is detected via accelerometer.
class PotholeImpact {
  final double impact;
  final String severity;

  PotholeImpact({required this.impact, required this.severity});
}

/// Encapsulates the accelerometer-based pothole detection logic.
///
/// Listens to raw accelerometer (for gravity vector) and user accelerometer
/// (for linear force), projects the linear force onto the gravity vector,
/// and scans for the drop-then-spike signature of a pothole impact.
class PotholePhysicsService {
  // --- Gravity vector (updated continuously) ---
  double _gx = 0.0, _gy = 0.0, _gz = 9.8;
  double _gravityMag = 9.8;

  // --- Pothole detection thresholds ---
  static const double _potholeImpactThreshold = 3.5;
  static const double _dropThreshold = -1.5;
  static const int _maxDropToImpactGap = 8;
  static const int _windowSize = 25;

  DateTime _lastDetectionTime = DateTime.now();
  final List<double> _verticalForceWindow = [];

  // --- Streams ---
  StreamSubscription<AccelerometerEvent>? _gravityStream;
  StreamSubscription<UserAccelerometerEvent>? _userAccelStream;

  // --- Output stream ---
  final StreamController<PotholeImpact> _impactController =
      StreamController<PotholeImpact>.broadcast();

  /// Stream that emits a [PotholeImpact] whenever a pothole signature is
  /// detected.
  Stream<PotholeImpact> get onImpact => _impactController.stream;

  /// The current speed in m/s — must be set by the caller (e.g. from GPS).
  double currentSpeedMps = 0.0;

  /// Start listening to accelerometer streams.
  void start() {
    // Stream 1: Raw accelerometer WITH gravity — tracks the gravity vector
    _gravityStream = accelerometerEventStream().listen((
      AccelerometerEvent event,
    ) {
      _gx = event.x;
      _gy = event.y;
      _gz = event.z;
      _gravityMag = sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    });

    // Stream 2: User accelerometer WITHOUT gravity — the linear force
    _userAccelStream = userAccelerometerEventStream().listen((
      UserAccelerometerEvent event,
    ) {
      final double verticalForce;
      if (_gravityMag > 0.1) {
        verticalForce =
            (event.x * _gx + event.y * _gy + event.z * _gz) / _gravityMag;
      } else {
        verticalForce = 0.0;
      }

      if (verticalForce.abs() > 1.0) {
        debugPrint(
          '[PHYSICS] 📐 Vertical: ${verticalForce.toStringAsFixed(2)} m/s² '
          '(raw: x=${event.x.toStringAsFixed(1)}, y=${event.y.toStringAsFixed(1)}, z=${event.z.toStringAsFixed(1)})',
        );
      }

      _verticalForceWindow.add(verticalForce);
      if (_verticalForceWindow.length > _windowSize) {
        _verticalForceWindow.removeAt(0);
      }

      if (_verticalForceWindow.length >= 10 &&
          DateTime.now().difference(_lastDetectionTime).inSeconds > 3) {
        _analyzePatternAndDetect();
      }
    });
  }

  void _analyzePatternAndDetect() {
    // Speed filter: ignore under ~15 km/h to filter parking lot bumps
    if (currentSpeedMps < 4.1) return;

    final window = _verticalForceWindow;
    double bestImpact = 0.0;
    bool signatureFound = false;

    for (int i = window.length - 1; i >= 1; i--) {
      if (window[i] > _potholeImpactThreshold && window[i] > bestImpact) {
        final searchStart = (i - _maxDropToImpactGap).clamp(0, i);
        for (int j = i - 1; j >= searchStart; j--) {
          if (window[j] < _dropThreshold) {
            bestImpact = window[i];
            signatureFound = true;
            debugPrint(
              '[PHYSICS] 🔍 Signature found: drop=${window[j].toStringAsFixed(2)} '
              'at [$j] → impact=${window[i].toStringAsFixed(2)} at [$i] '
              '(gap: ${i - j} samples)',
            );
            break;
          }
        }
      }
    }

    if (signatureFound) {
      _lastDetectionTime = DateTime.now();
      _verticalForceWindow.clear();

      final severity = bestImpact > 7.0 ? 'High' : 'Medium';
      _impactController.add(
        PotholeImpact(impact: bestImpact, severity: severity),
      );
    }
  }

  /// Stop listening and release resources.
  void dispose() {
    _gravityStream?.cancel();
    _userAccelStream?.cancel();
    _impactController.close();
  }
}
