import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/captured_pothole.dart';
import '../services/depth_severity_service.dart';

class LiveDetectionPage extends StatefulWidget {
  const LiveDetectionPage({super.key});

  @override
  State<LiveDetectionPage> createState() => _LiveDetectionPageState();
}

class _LiveDetectionPageState extends State<LiveDetectionPage> {
  // --- Map & GPS ---
  final MapController _miniMapController = MapController();
  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<UserAccelerometerEvent>? _userAccelStream;
  StreamSubscription<AccelerometerEvent>? _gravityStream;
  LatLng _currentLocation = const LatLng(11.2588, 75.7804);
  double _currentSpeedMps = 0.0;

  // --- PHYSICS CONFIGURATION ---
  // Gravity vector (updated continuously from accelerometerEventStream)
  double _gx = 0.0, _gy = 0.0, _gz = 9.8; // Default: phone flat, screen up
  double _gravityMag = 9.8;

  // Pothole detection thresholds
  static const double _potholeImpactThreshold =
      3.5; // Positive vertical spike (m/s²)
  static const double _dropThreshold =
      -1.5; // Negative vertical drop (freefall)
  static const int _maxDropToImpactGap =
      8; // Max samples between drop and impact
  DateTime _lastDetectionTime = DateTime.now();
  final List<double> _verticalForceWindow = [];
  static const int _windowSize = 25; // ~0.5s of data at ~50 Hz

  // --- YOLO controller (enforces thresholds on overlay rendering) ---
  final YOLOViewController _yoloController = YOLOViewController();

  // --- Detection state (updated by onStreamingData) ---
  int _potholeCount = 0;
  int _maxPotholesSession = 0;

  // --- MiDaS Capture Queue ---
  final List<CapturedPothole> _capturedPotholes = [];
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _captureCooldown = Duration(seconds: 5);
  bool _isProcessingDepth = false;

  @override
  void initState() {
    super.initState();
    _startNavigationMode();
    // Enforce thresholds via controller — this overrides the widget prop
    // and actually controls what the overlay renderer draws.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _yoloController.setThresholds(
        confidenceThreshold: 0.86,
        iouThreshold: 0.30,
        numItemsThreshold: 10,
      );
    });

    _startAccelerometerTracking();
  }

  // ── GPS ─────────────────────────────────────────────────────────────────────
  void _startNavigationMode() {
    _positionStreamSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
          ),
        ).listen((Position position) {
          _updateMapToFollowUser(LatLng(position.latitude, position.longitude));
          _currentSpeedMps = position.speed;
        });
  }

  void _updateMapToFollowUser(LatLng newPos) {
    if (!mounted) return;
    setState(() => _currentLocation = newPos);
    _miniMapController.move(_currentLocation, 17.0);
  }

  @override
  void dispose() {
    _yoloController.stop();
    _positionStreamSubscription?.cancel();
    _userAccelStream?.cancel();
    _gravityStream?.cancel();
    _miniMapController.dispose();
    super.dispose();
  }

  // ── BACKGROUND ACCELEROMETER (Gravity-Projected Vertical Force) ─────────────
  void _startAccelerometerTracking() {
    // Stream 1: Raw accelerometer WITH gravity — used to track the gravity vector
    _gravityStream = accelerometerEventStream().listen((
      AccelerometerEvent event,
    ) {
      _gx = event.x;
      _gy = event.y;
      _gz = event.z;
      _gravityMag = sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    });

    // Stream 2: User accelerometer WITHOUT gravity — the linear impact force
    _userAccelStream = userAccelerometerEventStream().listen((
      UserAccelerometerEvent event,
    ) {
      // ── Project linear acceleration onto gravity vector ──
      // dot(linear, gravity) / |gravity| gives the signed vertical component:
      //   positive = pushed UP (exit from hole)
      //   negative = pulled DOWN (freefall into hole)
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

      // Keep rolling window of vertical force readings
      _verticalForceWindow.add(verticalForce);
      if (_verticalForceWindow.length > _windowSize) {
        _verticalForceWindow.removeAt(0);
      }

      // Analyze pattern when we have enough data and cooldown has passed
      if (_verticalForceWindow.length >= 10 &&
          DateTime.now().difference(_lastDetectionTime).inSeconds > 3) {
        _analyzePatternAndDetect();
      }
    });
  }

  void _analyzePatternAndDetect() {
    // Speed filter: ignore under ~15 km/h to filter parking lot bumps
    if (_currentSpeedMps < 4.1) return;

    // ── POTHOLE SIGNATURE: Negative drop THEN positive impact ──
    // Scan backward from the end of the window looking for a positive spike
    // that was preceded by a negative drop within _maxDropToImpactGap samples.

    final window = _verticalForceWindow;
    double bestImpact = 0.0;
    bool signatureFound = false;

    // Look for positive spikes (exit impact)
    for (int i = window.length - 1; i >= 1; i--) {
      if (window[i] > _potholeImpactThreshold && window[i] > bestImpact) {
        // Found a spike — now look backward for a preceding negative drop
        final searchStart = (i - _maxDropToImpactGap).clamp(0, i);
        for (int j = i - 1; j >= searchStart; j--) {
          if (window[j] < _dropThreshold) {
            // ✅ Pothole signature confirmed: drop at [j] → impact at [i]
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
      // Clear window to prevent aftershock duplicates
      _verticalForceWindow.clear();
      _registerAccelerometerPotholeHit(bestImpact);
    }
  }

  Future<void> _registerAccelerometerPotholeHit(double impact) async {
    final severity = impact > 7.0 ? 'High' : 'Medium';
    debugPrint(
      '[PHYSICS] 💥 Pothole Signature Confirmed! Drop followed by Impact: ${impact.toStringAsFixed(2)} m/s² '
      '→ severity=$severity at '
      '(${_currentLocation.latitude.toStringAsFixed(5)}, ${_currentLocation.longitude.toStringAsFixed(5)})',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Pothole Detected! Vertical Impact: ${impact.toStringAsFixed(1)} m/s²",
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    try {
      await Supabase.instance.client.from('potholes').insert({
        'lat': _currentLocation.latitude,
        'lng': _currentLocation.longitude,
        'severity': severity,
        'status': 'Pending',
        'description':
            'Auto-detected: vertical pothole signature '
            '(impact: ${impact.toStringAsFixed(2)} m/s², '
            'speed: ${(_currentSpeedMps * 3.6).toStringAsFixed(1)} km/h)',
      });
      debugPrint('[PHYSICS] ✅ Saved to Supabase (severity=$severity)');
    } catch (e) {
      debugPrint('[PHYSICS] ❌ Supabase insert failed: $e');
    }
  }

  // ── STREAMING DATA HANDLER ──────────────────────────────────────────────────
  // Uses onStreamingData instead of onResult to access original image bytes.
  void _handleStreamingData(Map<String, dynamic> event) {
    // ── Parse performance metrics from streaming data ──
    // (onPerformanceMetrics is NOT called when onStreamingData is set)
    final fps = event['fps'];
    final processingTimeMs = event['processingTimeMs'];
    if (fps != null || processingTimeMs != null) {
      debugPrint(
        '⚡ FPS: ${(fps as num?)?.toDouble().toStringAsFixed(1) ?? '?'} | '
        '⏱️ Inference: ${(processingTimeMs as num?)?.toDouble().toStringAsFixed(1) ?? '?'}ms',
      );
    }

    // Parse detections from the raw streaming data
    final detectionsData = event['detections'] as List<dynamic>? ?? [];
    final potholes = <Map<String, dynamic>>[];

    for (final detection in detectionsData) {
      if (detection is! Map) continue;
      final confidence = (detection['confidence'] as num?)?.toDouble() ?? 0.0;
      if (confidence > 0.85) {
        potholes.add(Map<String, dynamic>.from(detection));
      }
    }

    // Update UI counts (same as before)
    if (potholes.isNotEmpty) {
      debugPrint(
        '${potholes.length} pothole(s) at '
        'Lat: ${_currentLocation.latitude}, '
        'Lng: ${_currentLocation.longitude}',
      );
    }

    if (mounted) {
      setState(() {
        _potholeCount = potholes.length;
        if (_potholeCount > _maxPotholesSession) {
          _maxPotholesSession = _potholeCount;
        }
      });
    }

    // ── Capture image for MiDaS if pothole detected ──
    if (potholes.isNotEmpty) {
      final now = DateTime.now();
      if (now.difference(_lastCaptureTime) < _captureCooldown) {
        debugPrint('⏳ Cooldown active, skipping capture');
        return;
      }
      _lastCaptureTime = now;

      // Get the original image bytes from the streaming data
      final imageBytes = event['originalImage'];
      if (imageBytes == null) {
        debugPrint('⚠️ No original image in streaming data');
        return;
      }

      // Use the highest-confidence detection's bounding box
      final bestDetection = potholes.reduce(
        (a, b) => (a['confidence'] as num) > (b['confidence'] as num) ? a : b,
      );

      // Extract normalized bounding box
      final normalizedBoxMap = bestDetection['normalizedBox'] as Map?;
      if (normalizedBoxMap == null) {
        debugPrint('⚠️ No normalizedBox in detection');
        return;
      }

      final normalizedBox = Rect.fromLTRB(
        (normalizedBoxMap['left'] as num?)?.toDouble() ?? 0.0,
        (normalizedBoxMap['top'] as num?)?.toDouble() ?? 0.0,
        (normalizedBoxMap['right'] as num?)?.toDouble() ?? 0.0,
        (normalizedBoxMap['bottom'] as num?)?.toDouble() ?? 0.0,
      );

      final confidence =
          (bestDetection['confidence'] as num?)?.toDouble() ?? 0.0;

      // Save image to temp directory in background
      _captureFrame(
        imageBytes is List<int> ? imageBytes : List<int>.from(imageBytes),
        normalizedBox,
        confidence,
      );
    }
  }

  Future<void> _captureFrame(
    List<int> imageBytes,
    Rect normalizedBox,
    double confidence,
  ) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${tempDir.path}/pothole_$timestamp.jpg';
      await File(filePath).writeAsBytes(imageBytes);

      // Insert into Supabase first, get back the ID
      String? supabaseId;
      try {
        final response = await Supabase.instance.client
            .from('potholes')
            .insert({
              'lat': _currentLocation.latitude,
              'lng': _currentLocation.longitude,
              'severity': 'Pending', // Will be updated by MiDaS
              'status': 'Pending',
              'description':
                  'YOLO-detected pothole (confidence: ${confidence.toStringAsFixed(2)}). Depth analysis queued.',
            })
            .select('id')
            .single();
        supabaseId = response['id']?.toString();
      } catch (e) {
        dev.log('⚠️ Supabase insert failed: $e', name: 'CAPTURE');
      }

      final capture = CapturedPothole(
        imagePath: filePath,
        normalizedBox: normalizedBox,
        lat: _currentLocation.latitude,
        lng: _currentLocation.longitude,
        confidence: confidence,
        supabaseId: supabaseId,
      );

      _capturedPotholes.add(capture);
      dev.log(
        '📸 Captured pothole frame: $filePath '
        '(queue: ${_capturedPotholes.length})',
        name: 'CAPTURE',
      );
    } catch (e) {
      dev.log('❌ Failed to capture frame: $e', name: 'CAPTURE');
    }
  }

  // ── SESSION END: Trigger MiDaS Pipeline ──────────────────────────────────────
  Future<void> _onSessionEnd() async {
    // 1. Show processing overlay IMMEDIATELY (hides YOLOView, prevents interaction)
    if (mounted) {
      setState(() => _isProcessingDepth = true);
    }

    // 2. Small delay to let the overlay render before we tear down the camera
    await Future.delayed(const Duration(milliseconds: 300));

    // 3. Stop YOLO model — frees camera and CPU/memory
    dev.log('🛑 Stopping YOLO model...', name: 'YOLO');
    try {
      await _yoloController.stop();
      dev.log('🛑 YOLO model stopped successfully', name: 'YOLO');
    } catch (e) {
      dev.log('⚠️ Error stopping YOLO: $e', name: 'YOLO');
    }

    // 4. Let the native camera teardown settle
    await Future.delayed(const Duration(milliseconds: 500));

    dev.log(
      '📊 Session summary: $_maxPotholesSession max potholes, '
      '${_capturedPotholes.length} frames captured for MiDaS',
      name: 'YOLO',
    );

    // 5. If no captures, just pop
    if (_capturedPotholes.isEmpty) {
      dev.log('🔬 No captures to process, exiting', name: 'MiDaS');
      if (mounted) {
        setState(() => _isProcessingDepth = false);
        Navigator.pop(context, _maxPotholesSession);
      }
      return;
    }

    // 6. Run MiDaS pipeline
    try {
      final results = await DepthSeverityService.processQueue(
        List.from(_capturedPotholes),
      );

      dev.log('🔬 Processed ${results.length} captures', name: 'MiDaS');
      for (final result in results) {
        dev.log(
          '   → ${result.severity} (dropoff: ${result.depthDropoff.toStringAsFixed(3)})',
          name: 'MiDaS',
        );
      }
    } catch (e) {
      dev.log('❌ Pipeline error: $e', name: 'MiDaS');
    } finally {
      _capturedPotholes.clear();
      if (mounted) {
        setState(() => _isProcessingDepth = false);
        Navigator.pop(context, _maxPotholesSession);
      }
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. YOLOView — handles camera, inference, and bounding boxes natively
          YOLOView(
            modelPath: 'new-dataset-yolov26_int8',
            task: YOLOTask.detect,
            // --- SPEED OPTIMIZATIONS ---
            useGpu: false,
            streamingConfig: YOLOStreamingConfig.throttled(
              maxFPS: 5,
              includeMasks: false,
              includeOriginalImage: true,
            ),
            // ---------------------------
            controller: _yoloController,
            showOverlays: true,
            confidenceThreshold: 0.86,
            iouThreshold: 0.30,
            // Use onStreamingData to access original image bytes
            onStreamingData: _handleStreamingData,
          ),

          // 2. LIVE indicator (top left)
          Positioned(
            top: 50,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.fiber_manual_record,
                    color: Colors.white,
                    size: 14,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'LIVE REC',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 3. Pothole count badge (top centre) — persistent
          Positioned(
            top: 50,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _potholeCount > 0
                      ? Colors.deepOrange.withValues(alpha: 0.9)
                      : Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Max Session: $_maxPotholesSession  |  Current: $_potholeCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),

          // 4. Capture queue indicator (below count badge)
          if (_capturedPotholes.isNotEmpty)
            Positioned(
              top: 95,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '📸 ${_capturedPotholes.length} frame(s) queued for depth analysis',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
            ),

          // 5. Mini Map (bottom right)
          Positioned(
            bottom: 30,
            right: 20,
            child: Container(
              width: 130,
              height: 180,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FlutterMap(
                  mapController: _miniMapController,
                  options: MapOptions(
                    initialCenter: _currentLocation,
                    initialZoom: 17.0,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName:
                          'com.sajay.potholewatch', //channge over here
                    ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _currentLocation,
                          width: 25,
                          height: 25,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.blueAccent,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: const [
                                BoxShadow(color: Colors.black26, blurRadius: 4),
                              ],
                            ),
                            child: const Icon(
                              Icons.navigation,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 6. Close button (top right) — triggers MiDaS pipeline
          Positioned(
            top: 50,
            right: 20,
            child: CircleAvatar(
              backgroundColor: Colors.black54,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _isProcessingDepth ? null : _onSessionEnd,
              ),
            ),
          ),

          // 7. MiDaS processing overlay
          if (_isProcessingDepth)
            Container(
              color: Colors.black.withValues(alpha: 0.7),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Colors.tealAccent),
                    const SizedBox(height: 20),
                    Text(
                      'Analyzing depth for ${_capturedPotholes.length} pothole(s)...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Running MiDaS depth estimation',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
