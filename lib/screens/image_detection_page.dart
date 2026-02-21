import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ultralytics_yolo/yolo.dart';

class ImageDetectionPage extends StatefulWidget {
  const ImageDetectionPage({super.key});

  @override
  State<ImageDetectionPage> createState() => _ImageDetectionPageState();
}

class _ImageDetectionPageState extends State<ImageDetectionPage> {
  final ImagePicker _picker = ImagePicker();
  File? _selectedImage;
  bool _isAnalyzing = false;
  List<dynamic> _detections = [];
  double _imageWidth = 0;
  double _imageHeight = 0;
  YOLO? _yolo;

  @override
  void initState() {
    super.initState();
    _initModel();
  }

  Future<void> _initModel() async {
    try {
      _yolo = YOLO(
        modelPath: 'yolov26_best_float32.tflite',
        task: YOLOTask.obb,
      );
      await _yolo?.loadModel();
    } catch (e) {
      debugPrint('Error loading model: $e');
    }
  }

  Future<void> _pickAndAnalyzeImage() async {
    final XFile? photo = await _picker.pickImage(source: ImageSource.gallery);
    if (photo == null || _yolo == null) return;

    setState(() {
      _selectedImage = File(photo.path);
      _isAnalyzing = true;
      _detections = []; // Reset old data
    });

    // 1. Get image physical dimensions to scale coordinates
    final decodedImage = await decodeImageFromList(
      await _selectedImage!.readAsBytes(),
    );
    _imageWidth = decodedImage.width.toDouble();
    _imageHeight = decodedImage.height.toDouble();

    // 2. Run inference using predict()!
    try {
      final imageBytes = await _selectedImage!.readAsBytes();
      final Map<String, dynamic>? resultData = await _yolo?.predict(
        imageBytes,
        confidenceThreshold: 0.70,
        iouThreshold: 0.30,
      );

      // Extract OBB nodes, filter out anything under 70% confidence
      if (resultData != null && resultData.containsKey('detections')) {
        final raw = List<dynamic>.from(resultData['detections']);

        // 🔍 Print ALL raw scores before filtering
        debugPrint('─────────────────────────────────────────');
        debugPrint('📊 RAW detections: ${raw.length} total');
        for (int i = 0; i < raw.length; i++) {
          final d = raw[i];
          if (d is Map) {
            final conf = (d['confidence'] as num?)?.toDouble() ?? 0.0;
            final cls = d['className'] ?? d['classIndex'] ?? '?';
            debugPrint(
              '  [$i] class=$cls  conf=${(conf * 100).toStringAsFixed(1)}%',
            );
            // 🔑 Dump all keys so we see the full structure
            debugPrint('       keys: ${d.keys.toList()}');
            if (d.containsKey('obb')) {
              debugPrint('       obb: ${d['obb']}');
            } else {
              debugPrint('       ⚠️ NO "obb" key! Full map: $d');
            }
          }
        }

        final filtered = raw.where((d) {
          if (d is! Map) return false;
          final conf = (d['confidence'] as num?)?.toDouble() ?? 0.0;
          return conf >= 0.70;
        }).toList();

        debugPrint('✅ After ≥70% filter: ${filtered.length} kept');
        debugPrint('─────────────────────────────────────────');

        setState(() {
          _detections = filtered;
        });
      }
    } catch (e) {
      debugPrint('Prediction failed: $e');
    }

    setState(() {
      _isAnalyzing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Image Analysis'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: Column(
          children: [
            Expanded(
              child: _selectedImage == null
                  ? const Center(
                      child: Text(
                        "Upload a photo to see Potholes",
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        return Stack(
                          alignment: Alignment.center,
                          children: [
                            // 1. the pure digital image
                            Image.file(
                              _selectedImage!,
                              fit: BoxFit.contain, // Maintain aspect ratio
                            ),

                            if (_isAnalyzing)
                              const CircularProgressIndicator(
                                color: Colors.red,
                              ),

                            // 2. The CustomPainter to overlay Native points over Boxfit.contain scaled size
                            if (!_isAnalyzing && _detections.isNotEmpty)
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: StaticOBBPainter(
                                    results: _detections,
                                    actualImageWidth: _imageWidth,
                                    actualImageHeight: _imageHeight,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
            ),

            Padding(
              padding: const EdgeInsets.all(24.0),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.photo_library),
                label: const Text('Pick Image from Gallery'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  backgroundColor: Colors.deepOrange,
                  foregroundColor: Colors.white,
                ),
                onPressed: _isAnalyzing ? null : _pickAndAnalyzeImage,
              ),
            ),

            // Stats footer
            if (_detections.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: Colors.white12,
                child: Text(
                  '✅ Found ${_detections.length} Potholes',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Custom Painter adjusted for Static Image Space (Not rotated camera space!)
class StaticOBBPainter extends CustomPainter {
  final List<dynamic> results;
  final double actualImageWidth;
  final double actualImageHeight;

  StaticOBBPainter({
    required this.results,
    required this.actualImageWidth,
    required this.actualImageHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (results.isEmpty || actualImageWidth == 0 || actualImageHeight == 0)
      return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.redAccent;

    // A static image rendered as BoxFit.contain doesn't completely fill the `size` container.
    // It is centered and padded. We have to map normalized [0.0 - 1.0] coordinates
    // into the ACTUAL painted dimensions of the image inside the device screen.
    final screenRatio = size.width / size.height;
    final imageRatio = actualImageWidth / actualImageHeight;

    double paintedWidth, paintedHeight, offsetX, offsetY;

    if (imageRatio > screenRatio) {
      // Image is wider than screen -> letterboxed top and bottom
      paintedWidth = size.width;
      paintedHeight = size.width / imageRatio;
      offsetX = 0;
      offsetY = (size.height - paintedHeight) / 2;
    } else {
      // Image is taller than screen -> pillarboxed left and right
      paintedWidth = size.height * imageRatio;
      paintedHeight = size.height;
      offsetX = (size.width - paintedWidth) / 2;
      offsetY = 0;
    }

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var detection in results) {
      if (detection is! Map) continue;

      // Static YOLO.predict() returns 'boundingBox' (LTRB normalized), NOT 'obb' polygon points.
      // 'obb' is only available in the live streaming API.
      final box = detection['boundingBox'];
      if (box is! Map) continue;

      double conf = (detection['confidence'] as num?)?.toDouble() ?? 0.0;

      // Extract normalized LTRB coordinates (can be slightly outside 0-1 range)
      double left = (box['left'] as num).toDouble();
      double top = (box['top'] as num).toDouble();
      double right = (box['right'] as num).toDouble();
      double bottom = (box['bottom'] as num).toDouble();

      // Clamp to valid range so boxes don't go off screen
      left = left.clamp(0.0, 1.0);
      top = top.clamp(0.0, 1.0);
      right = right.clamp(0.0, 1.0);
      bottom = bottom.clamp(0.0, 1.0);

      // Map normalized coords into the letterboxed/pillarboxed image area
      final x1 = offsetX + (left * paintedWidth);
      final y1 = offsetY + (top * paintedHeight);
      final x2 = offsetX + (right * paintedWidth);
      final y2 = offsetY + (bottom * paintedHeight);

      final rect = Rect.fromLTRB(x1, y1, x2, y2);
      canvas.drawRect(rect, paint);

      // Draw confidence label above the box
      textPainter.text = TextSpan(
        text: 'pothole ${(conf * 100).toStringAsFixed(1)}%',
        style: const TextStyle(
          color: Colors.redAccent,
          backgroundColor: Colors.black87,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x1, y1 - 20));
    }
  }

  @override
  bool shouldRepaint(covariant StaticOBBPainter oldDelegate) {
    return oldDelegate.results != results;
  }
}
