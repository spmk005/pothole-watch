import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';

// --- IMPORTS FOR YOUR APP ---
import '../models/pothole.dart';
import '../screens/login_page.dart';
import 'live_detection_page.dart'; // <--- MAKE SURE THIS FILE EXISTS

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedViewIndex = 0; // 0 = Map, 1 = List
  String _selectedSeverityFilter = 'All';

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

  Widget _buildListItem(Pothole pothole, int index) {
    Color badgeColor = _getMarkerColor(pothole.severity);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: (pothole.imageUrl != null && pothole.imageUrl!.isNotEmpty)
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(pothole.imageUrl!, fit: BoxFit.cover),
                  )
                : Icon(Icons.location_on, color: badgeColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Pothole #${index + 1}",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  pothole.description,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    "Severity: ${pothole.severity}",
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              pothole.status,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      // --- UPDATED APP BAR ---
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              "PotholeWatch",
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
            Text(
              "Tap map to report",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
        actions: [
          // 1. LIVE RECORDING BUTTON (NEW)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                elevation: 0,
              ),
              icon: const Icon(Icons.videocam, color: Colors.white, size: 18),
              label: const Text(
                "LIVE REC",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const LiveDetectionPage(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 10),

          // 2. PHOTO BUTTON (EXISTING)
          Padding(
            padding: const EdgeInsets.only(right: 16.0, top: 8, bottom: 8),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepOrange,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
              label: const Text("Photo", style: TextStyle(color: Colors.white)),
              onPressed: _pickImage,
            ),
          ),
        ],
      ),

      drawer: Drawer(
        child: ListView(
          children: [
            const DrawerHeader(
              child: Center(
                child: Icon(Icons.add_road, size: 50, color: Colors.orange),
              ),
            ),
            ListTile(
              title: const Text("Logout"),
              leading: const Icon(Icons.logout),
              onTap: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const LoginPage()),
              ),
            ),
          ],
        ),
      ),

      body: StreamBuilder<List<Pothole>>(
        stream: FirebaseFirestore.instance
            .collection('potholes')
            .snapshots()
            .map((snapshot) {
              return snapshot.docs
                  .map((doc) => Pothole.fromMap(doc.id, doc.data()))
                  .toList();
            }),
        builder: (context, snapshot) {
          final potholes = snapshot.data ?? [];

          List<Pothole> filteredPotholes = potholes;
          if (_selectedSeverityFilter != 'All') {
            filteredPotholes = potholes
                .where(
                  (p) =>
                      p.severity.toLowerCase() ==
                      _selectedSeverityFilter.toLowerCase(),
                )
                .toList();
          }

          int total = potholes.length;
          int pending = potholes.where((p) => p.status == 'Pending').length;
          int resolved = potholes.where((p) => p.status == 'fixed').length;

          return Column(
            children: [
              // STATS
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    _buildStatCard("Total", "$total", Colors.black),
                    const SizedBox(width: 10),
                    _buildStatCard("Pending", "$pending", Colors.red),
                    const SizedBox(width: 10),
                    _buildStatCard("Fixed", "$resolved", Colors.green),
                  ],
                ),
              ),

              // TOGGLE & FILTER
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedViewIndex = 0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _selectedViewIndex == 0
                                ? Colors.white
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: _selectedViewIndex == 0
                                ? [
                                    const BoxShadow(
                                      color: Colors.black12,
                                      blurRadius: 4,
                                    ),
                                  ]
                                : [],
                          ),
                          child: const Center(
                            child: Text(
                              "Map View",
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedViewIndex = 1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _selectedViewIndex == 1
                                ? Colors.white
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: _selectedViewIndex == 1
                                ? [
                                    const BoxShadow(
                                      color: Colors.black12,
                                      blurRadius: 4,
                                    ),
                                  ]
                                : [],
                          ),
                          child: const Center(
                            child: Text(
                              "List View",
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Row(
                  children: [
                    const Text(
                      "Filter: ",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    DropdownButton<String>(
                      value: _selectedSeverityFilter,
                      items: ['All', 'High', 'Medium', 'Low']
                          .map(
                            (val) =>
                                DropdownMenuItem(value: val, child: Text(val)),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => _selectedSeverityFilter = val!),
                    ),
                  ],
                ),
              ),

              // MAIN CONTENT (Map or List)
              Expanded(
                child: IndexedStack(
                  index: _selectedViewIndex,
                  children: [
                    // MAP VIEW
                    Stack(
                      children: [
                        FlutterMap(
                          mapController: _mapController,
                          options: MapOptions(
                            initialCenter: LatLng(11.2588, 75.7804),
                            initialZoom: 13.0,
                            onTap: (tapPosition, point) {
                              _showReportDialog(point);
                            },
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
                                      width: 40,
                                      height: 40,
                                      child: Icon(
                                        Icons.location_on,
                                        color: _getMarkerColor(p.severity),
                                        size: 40,
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                        if (_isUploading)
                          const Center(child: CircularProgressIndicator()),
                      ],
                    ),

                    // LIST VIEW
                    filteredPotholes.isEmpty
                        ? const Center(child: Text("No potholes found."))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: filteredPotholes.length,
                            itemBuilder: (context, index) =>
                                _buildListItem(filteredPotholes[index], index),
                          ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatCard(String title, String count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 5,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              count,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
