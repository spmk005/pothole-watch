import 'package:flutter/material.dart';
// Note: importing ultralytics_yolo.dart gives you YOLOView and all the task enums!
import 'package:ultralytics_yolo/ultralytics_yolo.dart'; 

class SimpleCameraPage extends StatelessWidget {
  const SimpleCameraPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Quick Camera Test'),
        backgroundColor: Colors.grey[900],
        foregroundColor: Colors.white,
      ),
      // Here is your exact snippet, plugged right into the body!
      body: YOLOView(
        modelPath: 'yolov26_best_float32.tflite', // 1. Added your actual model
        task: YOLOTask.obb,                       // 2. Switched to OBB
        showOverlays: true,                      // 3. Hides the red boxes
        onResult: (results) {
          // I added the strict 80% filter so it doesn't spam your console
          final strictPotholes = results.where((d) => d.confidence >= 0.8).toList();
          
          if (strictPotholes.isNotEmpty) {
            debugPrint('Detected ${strictPotholes.length} objects');
          }
        },
      ),
    );
  }
}