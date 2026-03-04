import 'package:ultralytics_yolo/models/yolo_result.dart';
import 'package:ultralytics_yolo/models/yolo_task.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';
import 'package:ultralytics_yolo/yolo_view.dart';
import 'package:ultralytics_yolo/yolo_streaming_config.dart'; 
import 'package:flutter/material.dart';

class CameraDetectionScreen extends StatefulWidget {
  @override
  _CameraDetectionScreenState createState() => _CameraDetectionScreenState();
}

class _CameraDetectionScreenState extends State<CameraDetectionScreen> {
  late YOLOViewController controller;
  List<YOLOResult> currentResults = [];
  
  final double minConfidence = 0.8; 

  @override
  void initState() {
    super.initState();
    controller = YOLOViewController();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          YOLOView(
            modelPath: 'no-obb-fp16-best',
            task: YOLOTask.detect,
            
            // --- SPEED OPTIMIZATIONS ---
            useGpu: true, // 2. FORCE hardware acceleration
            streamingConfig: YOLOStreamingConfig.throttled(
              maxFPS: 20, // 3. Limit to 20 FPS to prevent phone overheating
              includeMasks: false, // 4. Disable heavy segmentation math
              includeOriginalImage: false, // 5. Stop RAM-heavy image transfers
            ),
            // ---------------------------

            controller: controller,
            onResult: (results) {
              final highConfidenceResults = results.where((result) {
                return result.confidence != null && result.confidence! >= minConfidence;
              }).toList();

       
              if (currentResults.length != highConfidenceResults.length) {
                setState(() {
                  currentResults = highConfidenceResults;
                });
              }
            },
            onPerformanceMetrics: (metrics) {
              // Comment these out in production, printing to console takes processing power!
              // print('FPS: ${metrics.fps.toStringAsFixed(1)}');
              // print('Processing time: ${metrics.processingTimeMs.toStringAsFixed(1)}ms');
            },
          ),

          // Overlay UI
          Positioned(
            top: 50,
            left: 20,
            child: Container(
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Potholes: ${currentResults.length}',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}