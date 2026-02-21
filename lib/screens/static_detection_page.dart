import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:ultralytics_yolo/widgets/yolo_overlay.dart'; // Used to draw the boxes

class StaticImageDetectionPage extends StatefulWidget {
  const StaticImageDetectionPage({super.key});

  @override
  State<StaticImageDetectionPage> createState() =>
      _StaticImageDetectionPageState();
}

class _StaticImageDetectionPageState extends State<StaticImageDetectionPage> {
  final ImagePicker _picker = ImagePicker();
  Uint8List? _imageBytes;
  bool _isProcessing = false;

  // The YOLO brain for static images
  YOLO? _yolo;
  YOLODetectionResults? _detectionResults;

  @override
  void initState() {
    super.initState();
    _initModel();
  }

  Future<void> _initModel() async {
    _yolo = YOLO(
      modelPath: 'yolov26_best_float32.tflite', // Your model
      task: YOLOTask.obb, // OBB Task
    );
    await _yolo!.loadModel();
    debugPrint("✅ YOLO Model Loaded for Static Images!");
  }

  // 2. Pick the image and run inference
  Future<void> _pickAndDetectImage(ImageSource source) async {
    final XFile? pickedFile = await _picker.pickImage(source: source);
    if (pickedFile == null) return;

    final bytes = await pickedFile.readAsBytes();

    setState(() {
      _imageBytes = bytes;
      _isProcessing = true;
      _detectionResults = null; // Clear old boxes
    });

    if (_yolo != null) {
      // Run the image through the AI
      final map = await _yolo!.predict(
        bytes,
        confidenceThreshold: 0.8, // Lowered to 10% so it's not shy
      );

      setState(() {
        _detectionResults = YOLODetectionResults.fromMap(map);
        _isProcessing = false;
      });

      debugPrint(
        '🛑 AI Finished! Potholes found: ${_detectionResults?.detections.length}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Analyze Photo',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        children: [
          // --- IMAGE & BOXES DISPLAY ---
          Expanded(
            child: Center(
              child: _imageBytes == null
                  ? const Text(
                      'Take a photo of a pothole',
                      style: TextStyle(color: Colors.white70, fontSize: 18),
                    )
                  : Stack(
                      alignment: Alignment.center,
                      children: [
                        // The raw image
                        Image.memory(_imageBytes!, fit: BoxFit.contain),

                        // The painted OBB boxes automatically drawn by the package
                        if (_detectionResults != null)
                          Positioned.fill(
                            child: YOLOOverlay(
                              detections: _detectionResults!.detections,
                            ),
                          ),

                        // Loading spinner
                        if (_isProcessing)
                          const CircularProgressIndicator(
                            color: Colors.redAccent,
                          ),
                      ],
                    ),
            ),
          ),

          // --- CONTROLS ---
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: SafeArea(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white24,
                    ),
                    onPressed: _isProcessing
                        ? null
                        : () => _pickAndDetectImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt, color: Colors.white),
                    label: const Text(
                      "Camera",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    onPressed: _isProcessing
                        ? null
                        : () => _pickAndDetectImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library, color: Colors.white),
                    label: const Text(
                      "Gallery",
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
