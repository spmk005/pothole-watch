import 'package:latlong2/latlong.dart';

class Pothole {
  final String id;
  final LatLng point;
  final String? imageUrl;
  final String description;
  final String status;
  final String severity; // <--- NEW FIELD

  Pothole({
    required this.id,
    required this.point,
    this.imageUrl,
    this.description = '',
    this.status = 'reported',
    this.severity = 'Medium', // Default if missing
  });

  factory Pothole.fromMap(String id, Map<String, dynamic> data) {
    return Pothole(
      id: id,
      point: LatLng(
        (data['lat'] as num).toDouble(),
        (data['lng'] as num).toDouble(),
      ),
      imageUrl: data['imageUrl'],
      description: data['description'] ?? '',
      status: data['status'] ?? 'reported',
      severity: data['severity'] ?? 'Medium', // <--- Read from Firebase
    );
  }
}
