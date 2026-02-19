import 'dart:async'; // For Timer
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart'; // 1. Added YOLO package

class LiveDetectionPage extends StatefulWidget {
  const LiveDetectionPage({super.key});

  @override
  State<LiveDetectionPage> createState() => _LiveDetectionPageState();
}

class _LiveDetectionPageState extends State<LiveDetectionPage> {
  // We completely removed CameraController. YOLOView handles it now!
  final MapController _miniMapController = MapController();

  // Real GPS Stream & Simulation
  StreamSubscription<Position>? _positionStreamSubscription;
  Timer? _simulationTimer;
  bool _isSimulating = false;

  LatLng _currentLocation = const LatLng(11.2588, 75.7804); // Default

  @override
  void initState() {
    super.initState();
    _startNavigationMode(); 
  }

  // --- 1. REAL NAVIGATION ---
  void _startNavigationMode() async {
    // Note: Ensure you request location permissions before this runs in production!
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

  // --- 2. FAKE NAVIGATION (Simulation) ---
  void _toggleSimulation() {
    if (_isSimulating) {
      _simulationTimer?.cancel();
      setState(() => _isSimulating = false);
    } else {
      setState(() => _isSimulating = true);
      _simulationTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
        double newLat = _currentLocation.latitude + 0.00005;
        double newLng = _currentLocation.longitude + 0.00005;
        _updateMapToFollowUser(LatLng(newLat, newLng));
      });
    }
  }

  // --- SHARED: Update Map ---
  void _updateMapToFollowUser(LatLng newPos) {
    if (!mounted) return;
    setState(() {
      _currentLocation = newPos;
    });
    _miniMapController.move(_currentLocation, 17.0);
  }

  @override
  void dispose() {
    _miniMapController.dispose();
    _positionStreamSubscription?.cancel();
    _simulationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 1. THE BRAIN: YOLO Camera Feed replacing the standard CameraPreview
// 1. THE BRAIN: YOLO Camera Feed
// 1. THE BRAIN: YOLO Camera Feed
          SizedBox.expand(
            child: YOLOView(
              modelPath: 'yolov26_best_float32.tflite', 
              task: YOLOTask.obb,
              
              // 🔴 THE MAGIC SWITCH: This completely hides all bounding boxes and labels
              showOverlays: false, 
              
              onResult: (results) {
                // 1. THE BOUNCER: Filter out the weak 66% detections
                final strictPotholes = results.where((detection) {
                  return detection.confidence >= 0.8; 
                }).toList();
                
                // 2. THE ALERT: Only fires when it is 80%+ sure
                if (strictPotholes.isNotEmpty) {
                  debugPrint('🚨 POTHOLE DETECTED (High Confidence!) at Lat: ${_currentLocation.latitude}, Lng: ${_currentLocation.longitude}');
                }
              },
            ),
          ),          // 2. LIVE Indicator
          Positioned(
            top: 50,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                children: [
                  Icon(Icons.fiber_manual_record, color: Colors.white, size: 14),
                  SizedBox(width: 8),
                  Text("LIVE REC", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),

          // 3. Mini Map
          Positioned(
            bottom: 30,
            right: 20,
            child: Container(
              width: 130,
              height: 180,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(15),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10)],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FlutterMap(
                  mapController: _miniMapController,
                  options: MapOptions(
                    initialCenter: _currentLocation,
                    initialZoom: 17.0,
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                  ),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
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
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                            ),
                            child: const Icon(Icons.navigation, color: Colors.white, size: 14),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 4. "TEST DRIVE" BUTTON
          Positioned(
            bottom: 30,
            left: 20,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _isSimulating ? Colors.orange : Colors.green,
              ),
              onPressed: _toggleSimulation,
              icon: Icon(_isSimulating ? Icons.stop : Icons.play_arrow),
              label: Text(_isSimulating ? "Stop Sim" : "Test Drive"),
            ),
          ),

          // 5. Close Button
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