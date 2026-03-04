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
        double.tryParse(data['lat']?.toString() ?? '0') ?? 0.0,
        double.tryParse(data['lng']?.toString() ?? '0') ?? 0.0,
      ),
      imageUrl: data['imageUrl']?.toString(),
      description: data['description']?.toString() ?? '',
      status: data['status']?.toString() ?? 'reported',
      severity: data['severity']?.toString() ?? 'Medium',
    );
  }
}
