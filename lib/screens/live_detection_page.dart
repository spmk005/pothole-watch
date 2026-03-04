import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';

class LiveDetectionPage extends StatefulWidget {
  const LiveDetectionPage({super.key});

  @override
  State<LiveDetectionPage> createState() => _LiveDetectionPageState();
}

class _LiveDetectionPageState extends State<LiveDetectionPage> {
  // --- Map & GPS ---
  final MapController _miniMapController = MapController();
  StreamSubscription<Position>? _positionStreamSubscription;
  Timer? _simulationTimer;
  bool _isSimulating = false;
  LatLng _currentLocation = const LatLng(11.2588, 75.7804);

  // --- YOLO controller (enforces thresholds on overlay rendering) ---
  final YOLOViewController _yoloController = YOLOViewController();

  // --- Detection state (updated by YOLOView.onResult) ---
  int _potholeCount = 0;

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
          if (!_isSimulating) {
            _updateMapToFollowUser(
              LatLng(position.latitude, position.longitude),
            );
          }
        });
  }

  void _toggleSimulation() {
    if (_isSimulating) {
      _simulationTimer?.cancel();
      setState(() => _isSimulating = false);
    } else {
      setState(() => _isSimulating = true);
      _simulationTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        _updateMapToFollowUser(
          LatLng(
            _currentLocation.latitude + 0.00005,
            _currentLocation.longitude + 0.00005,
          ),
        );
      });
    }
  }

  void _updateMapToFollowUser(LatLng newPos) {
    if (!mounted) return;
    setState(() => _currentLocation = newPos);
    _miniMapController.move(_currentLocation, 17.0);
  }

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _positionStreamSubscription?.cancel();
    _miniMapController.dispose();
    super.dispose();
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
              maxFPS: 20,
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
                  '🚨 ${potholes.length} pothole(s) at '
                  'Lat: ${_currentLocation.latitude}, '
                  'Lng: ${_currentLocation.longitude}',
                );
              }

              if (mounted) {
                setState(() => _potholeCount = potholes.length);
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

          // 3. Pothole count badge (top centre) — only shown when detecting
          if (_potholeCount > 0)
            Positioned(
              top: 50,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.deepOrange.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '🚧 $_potholeCount pothole${_potholeCount > 1 ? 's' : ''} detected',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
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

          // 5. Test Drive simulation button (bottom left)
          Positioned(
            bottom: 30,
            left: 20,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _isSimulating ? Colors.orange : Colors.green,
              ),
              onPressed: _toggleSimulation,
              icon: Icon(_isSimulating ? Icons.stop : Icons.play_arrow),
              label: Text(_isSimulating ? 'Stop Sim' : 'Test Drive'),
            ),
          ),

          // 6. Close button (top right)
          Positioned(
            top: 50,
            right: 20,
            child: CircleAvatar(
              backgroundColor: Colors.black54,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
