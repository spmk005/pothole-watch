import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'dart:async';
import '../models/pothole.dart';
import 'live_detection_page.dart';
import 'login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentBottomNavIndex = 0;
  String _selectedSeverityFilter = 'All';
  int _scannerPotholesFound = 0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // --- CORE VARIABLES ---
  LatLng? _currentLocation;
  final MapController _mapController = MapController();
  bool _isUploading = false;

  // --- ALARM VARIABLES ---
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<List<Pothole>>? _potholesSubscription;
  List<Pothole> _allPotholes = [];
  final Set<String> _alertedPotholeIds = {};
  bool _isTrackingLocation = true;

  CameraController? _cameraController;

  @override
  void initState() {
    super.initState();
    _determinePosition();
    _initAlarmLogic();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;
      _cameraController = CameraController(
        cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Camera init error: $e");
    }
  }

  void _disposeCamera() {
    _cameraController?.dispose();
    _cameraController = null;
  }

  void _initAlarmLogic() {
    // 1. Listen for potholes from Supabase
    _potholesSubscription = Supabase.instance.client
        .from('potholes')
        .stream(primaryKey: ['id'])
        .map((data) => data.map((d) => Pothole.fromMap(d)).toList())
        .listen((potholes) {
          if (mounted) {
            setState(() {
              _allPotholes = potholes;
            });
          }
        });

    // 2. Listen for position updates
    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 5, // Update every 5 meters
          ),
        ).listen((Position position) {
          final currentPos = LatLng(position.latitude, position.longitude);
          if (mounted) {
            setState(() {
              _currentLocation = currentPos;
            });
            if (_isTrackingLocation && _currentBottomNavIndex == 1) {
              try {
                _mapController.move(currentPos, 15.0);
              } catch (e) {
                // Ignore map controller errors if not yet ready
              }
            }
          }
          _checkProximity(currentPos);
        });
  }

  void _checkProximity(LatLng currentPos) {
    const distanceCalculator = Distance();

    for (var pothole in _allPotholes) {
      // Filter by severity if necessary or just check all
      // Skip if already alerted for this pothole in this session
      if (_alertedPotholeIds.contains(pothole.id)) continue;

      // Calculate distance in meters
      double meters = distanceCalculator.as(
        LengthUnit.Meter,
        currentPos,
        pothole.point,
      );

      if (meters <= 15.0) {
        _triggerAlarm(pothole);
        break; // Trigger only one alarm at a time to avoid overlapping alerts
      }
    }
  }

  Future<void> _triggerAlarm(Pothole pothole) async {
    _alertedPotholeIds.add(pothole.id);

    // Play Alert Sound
    try {
      // Using a short notification sound from a public CDN for demonstration
      await _audioPlayer.play(
        UrlSource(
          'https://codeskulptor-demos.commondatastorage.googleapis.com/descent/gotitem.mp3',
        ),
      );
    } catch (e) {
      debugPrint("Error playing alarm sound: $e");
    }

    // Show visual warning
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.warning, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "🚨 POTHOLE AHEAD! (15m) \nSeverity: ${pothole.severity}",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          action: SnackBarAction(
            label: 'OK',
            textColor: Colors.white,
            onPressed: () {},
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _potholesSubscription?.cancel();
    _audioPlayer.dispose();
    _mapController.dispose();
    _disposeCamera();
    super.dispose();
  }

  // --- LOGIC: Location ---
  Future<void> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    try {
      Position position = await Geolocator.getCurrentPosition();
      setState(() {
        _currentLocation = LatLng(position.latitude, position.longitude);
      });
      try {
        if (_currentLocation != null) {
          _mapController.move(_currentLocation!, 15);
        }
      } catch (_) {
        // Map widget not rendered yet — will move when user opens MAP tab
      }
    } catch (e) {
      debugPrint("Location access denied or failed: $e");
    }
  }

  // --- LOGIC: Submit to Supabase ---
  Future<void> _submitReport(
    LatLng point,
    String severity,
    String description,
  ) async {
    setState(() => _isUploading = true);

    try {
      await Supabase.instance.client.from('potholes').insert({
        'lat': point.latitude,
        'lng': point.longitude,
        'severity': severity,
        'status': 'Pending',
        'description': description,
        // Supabase will automatically handle the timestamp and ID!
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Report Sent Successfully!"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint("Upload error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  } // tilll here changed

  // --- UI: Report Dialog ---
  void _showReportDialog(LatLng point) {
    String selectedSeverity = 'Medium';
    TextEditingController descController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Report Pothole"),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Severity:",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    DropdownButton<String>(
                      value: selectedSeverity,
                      isExpanded: true,
                      items: ['Low', 'Medium', 'High'].map((String value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        );
                      }).toList(),
                      onChanged: (newValue) {
                        setDialogState(() {
                          selectedSeverity = newValue!;
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: descController,
                      decoration: const InputDecoration(
                        labelText: "Description",
                        hintText: "e.g. Deep hole",
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel"),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepOrange,
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _submitReport(point, selectedSeverity, descController.text);
                  },
                  child: const Text(
                    "SUBMIT",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- UI: Marker Colors ---
  Color _getMarkerColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'high':
      case 'severe':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.yellow;
      case 'pending':
        return Colors.blueGrey;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentBottomNavIndex == 0) {
      return Scaffold(
        key: _scaffoldKey,
        extendBody: true, // Needed for floating bottom nav
        backgroundColor: Colors.white,
        drawer: _buildSidebar(),
        body: SafeArea(bottom: false, child: _buildScannerView()),
        bottomNavigationBar: _buildBottomNav(),
      );
    }
    return _buildMapScaffold();
  }

  Widget _buildBottomNav() {
    return Container(
      margin: const EdgeInsets.only(left: 16, right: 16, bottom: 20),
      decoration: BoxDecoration(
        color: const Color(
          0xFFF3F4F6,
        ), // matching the slightly grey background of the nav
        borderRadius: BorderRadius.circular(40),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(40),
        child: BottomNavigationBar(
          currentIndex: _currentBottomNavIndex,
          selectedItemColor: Colors.deepOrange,
          unselectedItemColor: Colors.blueGrey.shade400,
          showUnselectedLabels: true,
          type: BottomNavigationBarType.fixed,
          backgroundColor: const Color(0xFFF3F4F6),
          elevation: 0,
          selectedLabelStyle: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
          unselectedLabelStyle: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
          onTap: (index) {
            if (index == 2) {
              _scaffoldKey.currentState?.openDrawer();
              return;
            }
            setState(() => _currentBottomNavIndex = index);
          },
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.radar), label: "SCANNER"),
            BottomNavigationBarItem(icon: Icon(Icons.map), label: "MAP"),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: "SETTINGS",
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScannerView() {
    String locationString = _currentLocation != null
        ? "${_currentLocation!.latitude.toStringAsFixed(4)}° N, ${_currentLocation!.longitude.toStringAsFixed(4)}° W"
        : "Locating...";

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(
          left: 24.0,
          right: 24.0,
          top: 24.0,
          bottom: 100.0,
        ), // added bottom padding for floating bar
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 10),
            // Header Icon
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Colors.deepOrange,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 30),
            ),
            const SizedBox(height: 16),
            const Text(
              "PotholeWatch",
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              "Real-time hazard detection",
              style: TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 30),

            // Camera preview illustration card
            Container(
              height: 180,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [Color(0xFF4B4F54), Color(0xFF2E3135)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_cameraController != null &&
                        _cameraController!.value.isInitialized)
                      SizedBox.expand(
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width:
                                _cameraController!.value.previewSize?.height ??
                                1,
                            height:
                                _cameraController!.value.previewSize?.width ??
                                1,
                            child: CameraPreview(_cameraController!),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 80,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 1.5,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.deepOrange.withOpacity(0.1),
                              Colors.deepOrange,
                              Colors.deepOrange.withOpacity(0.1),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 40,
                      left: 50,
                      child: Container(
                        width: 140,
                        height: 90,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.deepOrange,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 25,
                      left: 50,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: const BoxDecoration(
                          color: Colors.deepOrange,
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(8),
                            topRight: Radius.circular(8),
                            bottomRight: Radius.circular(8),
                          ),
                        ),
                        child: const Text(
                          "POTHOLE\nDETECTED",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 15,
                      left: 15,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.location_on,
                              color: Colors.deepOrange,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              locationString,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Stats row
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "POTHOLES\nFOUND",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF475569),
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              "$_scannerPotholesFound",
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "DISTANCE\nSCANNED",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF475569),
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Text(
                              "4.2",
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Padding(
                              padding: EdgeInsets.only(bottom: 4),
                              child: Text(
                                "Miles",
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),

            // Start Detection button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6600),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  elevation: 4,
                  shadowColor: Colors.deepOrange.withOpacity(0.5),
                ),
                icon: const Icon(Icons.videocam, color: Colors.white, size: 24),
                label: const Text(
                  "Start Detection",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () async {
                  _disposeCamera();
                  final int? result = await Navigator.push<int>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LiveDetectionPage(),
                    ),
                  );
                  if (result != null && result > 0) {
                    setState(() {
                      _scannerPotholesFound += result;
                    });
                  }
                  _initCamera();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Confirm Logout"),
        content: const Text("Are you sure you want to logout?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Logout", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (e) {
        // Ignore errors for now
      }
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const LoginPage()),
        );
      }
    }
  }

  Widget _buildSidebar() {
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: const BoxDecoration(color: Colors.deepOrange),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.send, color: Colors.white, size: 40),
                  SizedBox(height: 10),
                  Text(
                    "PotholeWatch",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.home),
            title: const Text("Dashboard"),
            onTap: () => Navigator.pop(context),
          ),
          const Spacer(),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.redAccent),
            title: const Text(
              "Logout",
              style: TextStyle(color: Colors.redAccent),
            ),
            onTap: () {
              Navigator.pop(context); // Close drawer
              _logout();
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildMapScaffold() {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildSidebar(),
      extendBody: true,
      backgroundColor: const Color(0xFFF8F9FA),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 90.0),
        child: FloatingActionButton(
          heroTag: "trackLocationBtn",
          backgroundColor: _isTrackingLocation
              ? Colors.deepOrange
              : Colors.white,
          onPressed: () {
            setState(() => _isTrackingLocation = !_isTrackingLocation);
            if (_isTrackingLocation && _currentLocation != null) {
              _mapController.move(_currentLocation!, 15.0);
            }
          },
          child: Icon(
            Icons.my_location,
            color: _isTrackingLocation ? Colors.white : Colors.deepOrange,
          ),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const SizedBox(height: 16),
            // --- MAP / LIST AREA ---
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                // Listening directly to the Supabase table
                stream: Supabase.instance.client
                    .from('potholes')
                    .stream(primaryKey: ['id']),
                builder: (context, AsyncSnapshot<List<Map<String, dynamic>>> snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text("Error: ${snapshot.error}"));
                  }

                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  // Convert Supabase Map data directly into your Pothole objects
                  final potholes = snapshot.data!
                      .map((data) => Pothole.fromMap(data))
                      .toList();

                  List<Pothole> filteredPotholes = potholes.where((p) {
                    // 1. Filter out Fixed potholes
                    if (p.status.toLowerCase() == 'fixed') return false;

                    // 2. Filter by Severity if needed
                    if (_selectedSeverityFilter != 'All') {
                      return p.severity.toLowerCase() ==
                          _selectedSeverityFilter.toLowerCase();
                    }

                    return true;
                  }).toList();

                  return Stack(
                    children: [
                      // The Map
                      Container(
                        color: const Color(
                          0xFF2E2E2E,
                        ), // Fallback map background
                        child: FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: LatLng(11.2588, 75.7804),
                            initialZoom: 13.0,
                            onTap: (tapPosition, point) =>
                                _showReportDialog(point),
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.sajay.potholewatch',
                            ),
                            if (_currentLocation != null)
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: _currentLocation!,
                                    width: 20,
                                    height: 20,
                                    child: const Icon(
                                      Icons.my_location,
                                      color: Colors.blue,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            MarkerLayer(
                              markers: filteredPotholes
                                  .map(
                                    (p) => Marker(
                                      point: p.point,
                                      width: 60,
                                      height: 60,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Container(
                                            width: 60,
                                            height: 60,
                                            decoration: BoxDecoration(
                                              color: _getMarkerColor(
                                                p.severity,
                                              ).withOpacity(0.3),
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                          Container(
                                            width: 28,
                                            height: 28,
                                            decoration: BoxDecoration(
                                              color: _getMarkerColor(
                                                p.severity,
                                              ),
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.white,
                                                width: 1.5,
                                              ),
                                            ),
                                            child: const Icon(
                                              Icons.warning_amber_rounded,
                                              color: Colors.white,
                                              size: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),

                      // Filter overlays
                      Positioned(
                        top: 16,
                        left: 16,
                        right: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Filter
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.95),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    "Filter: ",
                                    style: TextStyle(
                                      color: Colors.blueGrey,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  DropdownButton<String>(
                                    value: _selectedSeverityFilter,
                                    isDense: true,
                                    underline: const SizedBox(),
                                    icon: const Icon(
                                      Icons.keyboard_arrow_down,
                                      size: 16,
                                      color: Colors.black,
                                    ),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black,
                                      fontSize: 13,
                                    ),
                                    items:
                                        [
                                              'All',
                                              'Severe',
                                              'High',
                                              'Medium',
                                              'Low',
                                              'Pending',
                                            ]
                                            .map(
                                              (val) => DropdownMenuItem(
                                                value: val,
                                                child: Text(val),
                                              ),
                                            )
                                            .toList(),
                                    onChanged: (val) => setState(
                                      () => _selectedSeverityFilter = val!,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      if (_isUploading)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }
}
