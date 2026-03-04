import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pothole_watch/screens/cameradetectionscreen.dart';

import '../models/pothole.dart';
import 'live_detection_page.dart';
import 'login_page.dart';
// <--- MAKE SURE THIS FILE EXISTS

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
  final ImagePicker _picker = ImagePicker();
  Uint8List? _imageBytes;
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _determinePosition();
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

    Position position = await Geolocator.getCurrentPosition();
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
    });
    if (_currentLocation != null) {
      _mapController.move(_currentLocation!, 15);
    }
  }

  // --- LOGIC: Image Picker (Manual Report) ---
  Future<void> _pickImage() async {
    final XFile? photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 40,
    );
    if (photo != null) {
      final bytes = await photo.readAsBytes();
      setState(() => _imageBytes = bytes);

      // If they pick an image via button, assume current location
      if (_currentLocation != null) {
        _showReportDialog(_currentLocation!);
      }
    }
  }

  // --- LOGIC: Submit to Firestore ---
  Future<void> _submitReport(
    LatLng point,
    String severity,
    String description,
  ) async {
    setState(() => _isUploading = true);

    // Upload Image first (if exists)
    String? imageUrl;
    if (_imageBytes != null) {
      try {
        String fileName = DateTime.now().millisecondsSinceEpoch.toString();
        Reference storageRef = FirebaseStorage.instance.ref().child(
          'pothole_images/$fileName.jpg',
        );
        await storageRef.putData(
          _imageBytes!,
          SettableMetadata(contentType: 'image/jpeg'),
        );
        imageUrl = await storageRef.getDownloadURL();
      } catch (e) {
        print("Error uploading: $e");
      }
    }

    // Add to Firestore
    await FirebaseFirestore.instance.collection('potholes').add({
      'lat': point.latitude,
      'lng': point.longitude,
      'severity': severity,
      'status': 'Pending',
      'description': description,
      'imageUrl': imageUrl,
      'timestamp': FieldValue.serverTimestamp(),
    });

    setState(() {
      _isUploading = false;
      _imageBytes = null;
    });

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Report Sent Successfully!")));
  }

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
                    if (_imageBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          _imageBytes!,
                          height: 100,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      ),
                    const SizedBox(height: 10),

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
        return Colors.red;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.yellow;
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
              child: Stack(
                children: [
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
                        border: Border.all(color: Colors.deepOrange, width: 2),
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
      backgroundColor: const Color(0xFF424242),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const SizedBox(height: 16), // Replacement for top spacing
            // --- 3 Action Buttons ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF0F0F0),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 0,
                      ),
                      icon: const Icon(
                        Icons.verified,
                        color: Color(0xFF333333),
                        size: 16,
                      ),
                      label: const Text(
                        "VERIFY",
                        style: TextStyle(
                          color: Color(0xFF333333),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CameraDetectionScreen(),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF0F0F0),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        elevation: 0,
                      ),
                      icon: const Icon(
                        Icons.camera_alt,
                        color: Color(0xFF333333),
                        size: 16,
                      ),
                      label: const Text(
                        "PHOTO",
                        style: TextStyle(
                          color: Color(0xFF333333),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: _pickImage,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // --- MAP / LIST AREA ---
            Expanded(
              child: StreamBuilder<List<Pothole>>(
                stream: FirebaseFirestore.instance
                    .collection('potholes')
                    .snapshots()
                    .map((snapshot) {
                      return snapshot.docs
                          .map(
                            (doc) => Pothole.fromMap(
                              doc.id,
                              doc.data() as Map<String, dynamic>? ?? {},
                            ),
                          )
                          .toList();
                    }),
                builder: (context, snapshot) {
                  final potholes = snapshot.data ?? [];
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
                                    items: ['All', 'High', 'Medium', 'Low']
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
