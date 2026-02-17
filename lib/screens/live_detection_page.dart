import 'dart:async'; // For Timer
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';

class LiveDetectionPage extends StatefulWidget {
  const LiveDetectionPage({super.key});

  @override
  State<LiveDetectionPage> createState() => _LiveDetectionPageState();
}

class _LiveDetectionPageState extends State<LiveDetectionPage> {
  CameraController? _cameraController;
  final MapController _miniMapController = MapController();

  // Real GPS Stream
  StreamSubscription<Position>? _positionStreamSubscription;

  // Fake Simulation Timer
  Timer? _simulationTimer;
  bool _isSimulating = false;

  LatLng _currentLocation = const LatLng(11.2588, 75.7804); // Default
  bool _isCameraInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _startNavigationMode(); // Start real GPS (won't move on laptop)
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    if (cameras.isNotEmpty) {
      _cameraController = CameraController(
        cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() => _isCameraInitialized = true);
    }
  }

  // --- 1. REAL NAVIGATION (For Mobile) ---
  void _startNavigationMode() async {
    _positionStreamSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
          ),
        ).listen((Position position) {
          // Only use real GPS if NOT simulating
          if (!_isSimulating) {
            _updateMapToFollowUser(
              LatLng(position.latitude, position.longitude),
            );
          }
        });
  }

  // --- 2. FAKE NAVIGATION (For Chrome Testing) ---
  void _toggleSimulation() {
    if (_isSimulating) {
      _simulationTimer?.cancel();
      setState(() => _isSimulating = false);
    } else {
      setState(() => _isSimulating = true);
      // Move 0.0001 degrees every 200ms (Simulates driving fast)
      _simulationTimer = Timer.periodic(const Duration(milliseconds: 200), (
        timer,
      ) {
        double newLat = _currentLocation.latitude + 0.00005;
        double newLng = _currentLocation.longitude + 0.00005;
        _updateMapToFollowUser(LatLng(newLat, newLng));
      });
    }
  }

  // --- SHARED: Update Map & Marker ---
  void _updateMapToFollowUser(LatLng newPos) {
    if (!mounted) return;

    setState(() {
      _currentLocation = newPos;
    });

    // FORCE MAP TO MOVE
    _miniMapController.move(
      _currentLocation,
      17.0, // Keep zoom tight for navigation feel
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _miniMapController.dispose();
    _positionStreamSubscription?.cancel();
    _simulationTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCameraInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.red)),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          // 1. Camera Feed
          SizedBox.expand(child: CameraPreview(_cameraController!)),

          // 2. LIVE Indicator
          Positioned(
            top: 50,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.9),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: const [
                  Icon(
                    Icons.fiber_manual_record,
                    color: Colors.white,
                    size: 14,
                  ),
                  SizedBox(width: 8),
                  Text(
                    "LIVE REC",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 3. Mini Map (Bottom Right)
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
                    color: Colors.black.withOpacity(0.5),
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
                      flags: InteractiveFlag.none, // Lock map
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
                              boxShadow: [
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

          // 4. "TEST DRIVE" BUTTON (Bottom Left - For Chrome Testing Only)
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
