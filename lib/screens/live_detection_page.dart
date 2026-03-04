import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:math';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LiveDetectionPage extends StatefulWidget {
  const LiveDetectionPage({super.key});

  @override
  State<LiveDetectionPage> createState() => _LiveDetectionPageState();
}

class _LiveDetectionPageState extends State<LiveDetectionPage> {
  // --- Map & GPS ---
  final MapController _miniMapController = MapController();
  StreamSubscription<Position>? _positionStreamSubscription;
  StreamSubscription<UserAccelerometerEvent>? _accelerometerStream;
  LatLng _currentLocation = const LatLng(11.2588, 75.7804);
  double _currentSpeedMps = 0.0;

  // --- ALGORITHM CONFIGURATION ---
  final double _potholeThreshold =
      4.0; // Lowered slightly since magnitude is spread across 3 axes
  DateTime _lastDetectionTime = DateTime.now();
  final List<double> _accelerationWindow = [];
  final int _windowSize = 25; // Roughly 0.5s of data based on typical sensor Hz

  // --- YOLO controller (enforces thresholds on overlay rendering) ---
  final YOLOViewController _yoloController = YOLOViewController();

  // --- Detection state (updated by YOLOView.onResult) ---
  int _potholeCount = 0;
  int _maxPotholesSession = 0;

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
    _positionStreamSubscription?.cancel();
    _accelerometerStream?.cancel();
    _miniMapController.dispose();
    super.dispose();
  }

  // ── BACKGROUND ACCELEROMETER ────────────────────────────────────────────────
  void _startAccelerometerTracking() {
    _accelerometerStream = userAccelerometerEventStream().listen((
      UserAccelerometerEvent event,
    ) {
      // 1. Calculate the total vector magnitude of acceleration (removes gravity & phone orientation dependence)
      double magnitude = sqrt(
        event.x * event.x + event.y * event.y + event.z * event.z,
      );

      // We only care about the change in force (spikes), standard resting magnitude approaches 0
      // since userAccelerometerEventStream removes gravity automatically in Flutter

      if (magnitude > 1.0) {
        debugPrint(
          "🚗 Accelerometer Spike (Live Mode): ${magnitude.toStringAsFixed(2)}",
        );
      }

      // 2. Keep a rolling window of recent readings to find patterns
      _accelerationWindow.add(magnitude);
      if (_accelerationWindow.length > _windowSize) {
        _accelerationWindow.removeAt(0);
      }

      // 3. Analyze the recent pattern and current speed
      if (_accelerationWindow.length >= 10 &&
          DateTime.now().difference(_lastDetectionTime).inSeconds > 3) {
        _analyzePatternAndDetect();
      }
    });
  }

  void _analyzePatternAndDetect() {
    // Check 1: Speed filter. If going under ~15 km/h (4.1 m/s), totally ignore.
    // This filters out speed bumps right off the bat, as people usually hit them slow.
    if (_currentSpeedMps < 4.1) return;

    // Check 2: The pattern. A pothole involves a sharp drop (which in the userAccelerometer
    // creates a brief drop in force as the car goes into freefall) immediately matched by a
    // massive corrective positive jolt.
    double maxJolt = 0.0;
    int joltIndex = -1;

    // Because userAccelerometerEventStream removes gravity and is an absolute magnitude calculation,
    // we just look for ONE massive outlier in the window that indicates a severe hit
    for (int i = 0; i < _accelerationWindow.length; i++) {
      if (_accelerationWindow[i] > _potholeThreshold &&
          _accelerationWindow[i] > maxJolt) {
        maxJolt = _accelerationWindow[i];
        joltIndex = i;
      }
    }

    if (joltIndex != -1) {
      _lastDetectionTime = DateTime.now();
      // Passing the massive jolt reading to the reporter
      _registerAccelerometerPotholeHit(maxJolt);
    }
  }

  Future<void> _registerAccelerometerPotholeHit(double impact) async {
    debugPrint(
      "ACCELEROMETER POTHOLE DETECTED! Impact: ${impact.toStringAsFixed(2)}",
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Physical Bump Detected! Impact: ${impact.toStringAsFixed(1)}",
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    try {
      await Supabase.instance.client.from('potholes').insert({
        'latitude': _currentLocation.latitude,
        'longitude': _currentLocation.longitude,
        'severity': impact > 7.0 ? 'High' : 'Medium',
        'status': 'Pending',
        'description':
            'Auto-detected via Y-Axis accelerometer (Live Mode). Force: ${impact.toStringAsFixed(2)}',
      });
    } catch (e) {
      debugPrint("Error saving auto-pothole: $e");
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
            modelPath: 'no-obb-best_float16',
            task: YOLOTask.detect,
            // --- SPEED OPTIMIZATIONS ---
            useGpu: true,
            streamingConfig: YOLOStreamingConfig.throttled(
              maxFPS: 25,
              includeMasks: false,
              includeOriginalImage: false,
            ),
            // ---------------------------
            controller: _yoloController,
            showOverlays: true,
            confidenceThreshold: 0.86,
            iouThreshold: 0.30,
            onResult: (results) {
              final potholes = results
                  .where((d) => d.confidence > 0.85)
                  .toList();

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
            },
            onPerformanceMetrics: (metrics) {
              // Comment these out in production, printing to console takes processing power!
              // debugPrint('FPS: ${metrics.fps.toStringAsFixed(1)}');
              // debugPrint('Processing time: ${metrics.processingTimeMs.toStringAsFixed(1)}ms');
            },
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

          // 4. Mini Map (bottom right)
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

          // 5. Close button (top right)
          Positioned(
            top: 50,
            right: 20,
            child: CircleAvatar(
              backgroundColor: Colors.black54,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context, _maxPotholesSession),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
