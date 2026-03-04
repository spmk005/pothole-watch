import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/pothole.dart';

class AdminMapPage extends StatefulWidget {
  final String? initialSeverity;
  final String? initialStatusFilter;
  const AdminMapPage({
    super.key,
    this.initialSeverity,
    this.initialStatusFilter,
  });

  @override
  State<AdminMapPage> createState() => _AdminMapPageState();
}

class _AdminMapPageState extends State<AdminMapPage> {
  static const Color textColorPrimary = Color(0xFF0F172A);
  static const Color textColorSecondary = Color(0xFF64748B);

  final MapController _mapController = MapController();

  Color _getMarkerColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'high':
        return Colors.red;
      case 'medium':
      case 'med':
        return Colors.orange;
      case 'low':
        return Colors.green;
      default:
        return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Pothole Map',
          style: TextStyle(
            color: textColorPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: textColorPrimary),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: StreamBuilder<List<Pothole>>(
        stream: FirebaseFirestore.instance
            .collection('potholes')
            .snapshots()
            .map((snapshot) {
              var list = snapshot.docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>? ?? {};
                return Pothole.fromMap({...data, 'id': doc.id});
              }).toList();

              if (widget.initialSeverity != null) {
                String filter = widget.initialSeverity!.toLowerCase();
                list = list.where((p) {
                  String s = p.severity.toLowerCase();
                  if (filter == 'medium' || filter == 'med') {
                    return s == 'medium' || s == 'med';
                  }
                  return s == filter;
                }).toList();
              }
              if (widget.initialStatusFilter != null &&
                  widget.initialStatusFilter != 'All') {
                String filterStatus =
                    widget.initialStatusFilter!.toLowerCase() == 'fixed'
                    ? 'fixed'
                    : 'pending';
                list = list
                    .where((p) => p.status.toLowerCase() == filterStatus)
                    .toList();
              }
              return list;
            }),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Error: ${snapshot.error}',
                style: TextStyle(color: Colors.red),
              ),
            );
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final potholes = snapshot.data ?? [];

          return FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: LatLng(11.2588, 75.7804), // Default center
              initialZoom: 13.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.pothole.watch',
              ),
              MarkerLayer(
                markers: potholes.map((p) {
                  return Marker(
                    point: p.point,
                    width: 45,
                    height: 45,
                    child: GestureDetector(
                      onTap: () {
                        _showPotholeDetail(context, p);
                      },
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: _getMarkerColor(
                                p.severity,
                              ).withOpacity(0.2),
                              shape: BoxShape.circle,
                            ),
                            width: 35,
                            height: 35,
                          ),
                          Icon(
                            p.status.toLowerCase() == 'fixed'
                                ? Icons.check_circle
                                : Icons.location_on,
                            color: p.status.toLowerCase() == 'fixed'
                                ? Colors.green
                                : _getMarkerColor(p.severity),
                            size: 35,
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showPotholeDetail(BuildContext context, Pothole pothole) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Pothole Details',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: textColorPrimary,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _getMarkerColor(pothole.severity).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      pothole.severity.toUpperCase(),
                      style: TextStyle(
                        color: _getMarkerColor(pothole.severity),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              if (pothole.imageUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    pothole.imageUrl!,
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      height: 200,
                      color: Colors.grey[200],
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  ),
                ),
              const SizedBox(height: 15),
              Text(
                pothole.description.isEmpty
                    ? 'No description provided'
                    : pothole.description,
                style: const TextStyle(fontSize: 16, color: textColorPrimary),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.info_outline,
                    size: 16,
                    color: textColorSecondary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Status: ${pothole.status}',
                    style: const TextStyle(color: textColorSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (pothole.status.toLowerCase() != 'fixed')
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () async {
                      await FirebaseFirestore.instance
                          .collection('potholes')
                          .doc(pothole.id.toString())
                          .update({'status': 'fixed'});
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text(
                      'Mark as Completed',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              if (pothole.status.toLowerCase() == 'fixed')
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      side: const BorderSide(color: Colors.green),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'Completed',
                      style: TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Close',
                    style: TextStyle(color: textColorSecondary),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
