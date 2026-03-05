import 'package:latlong2/latlong.dart';

class Pothole {
  final String id; // <--- Changed back to String for Supabase UUIDs
  final LatLng point;
  final String severity;
  final String status;
  final String description;
  final String? imageUrl;
  final String? address; // <--- ADDED to fix your HomePage error!

  Pothole({
    required this.id,
    required this.point,
    required this.severity,
    required this.status,
    required this.description,
    this.imageUrl,
    this.address,
  });

  // Updated factory method to match Supabase's exact column names
  factory Pothole.fromMap(Map<String, dynamic> data) {
    return Pothole(
      id: data['id']?.toString() ?? '',
      point: LatLng(
        (data['lat'] as num).toDouble(),
        (data['lng'] as num).toDouble(),
      ),
      severity: data['severity'] ?? 'Medium',
      status: data['status'] ?? 'Pending',
      description: data['description'] ?? '',
      imageUrl: data['image_url'],
      address: data['address'],
    );
  }
}
