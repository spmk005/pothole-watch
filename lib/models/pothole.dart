import 'package:latlong2/latlong.dart';

class Pothole {
  final int id; // <--- Changed to 'int' for Supabase
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
      id: data['id'] is int
          ? data['id']
          : int.tryParse(data['id'].toString()) ?? 0,
      point: LatLng(
        (data['latitude'] as num)
            .toDouble(), // Supabase uses 'latitude', not 'lat'
        (data['longitude'] as num)
            .toDouble(), // Supabase uses 'longitude', not 'lng'
      ),
      severity: data['severity'] ?? 'Medium',
      status: data['status'] ?? 'Pending',
      description: data['description'] ?? '',
      imageUrl: data['image_url'],
      address: data['address'],
    );
  }
}
