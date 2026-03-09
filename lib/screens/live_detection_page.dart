import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';
import 'package:ultralytics_yolo/widgets/yolo_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/captured_pothole.dart';
import '../services/depth_severity_service.dart';
import '../services/pothole_physics_service.dart';
import '../repositories/pothole_repository.dart';

// ── Params class for background isolate image encoding ──────────────────────
class _EncodeParams {
  final List<int> imageBytes;
  final int width;
  final int height;
  _EncodeParams(this.imageBytes, {this.width = 0, this.height = 0});
}

Uint8List _encodeJpeg(_EncodeParams params) {
  var image = img.decodeImage(Uint8List.fromList(params.imageBytes));
  // Fallback: if decodeImage fails (e.g. raw YUV bytes), construct from raw
  if (image == null) {
    if (params.width > 0 && params.height > 0) {
      image = img.Image.fromBytes(
        width: params.width,
        height: params.height,
        bytes: Uint8List.fromList(params.imageBytes).buffer,
      );
    } else {
      throw Exception(
        'Failed to decode image and no width/height provided for fallback',
      );
    }
  }
  return img.encodeJpg(image, quality: 90);
}

class LiveDetectionPage extends StatefulWidget {
  const LiveDetectionPage({super.key});

  @override
  State<LiveDetectionPage> createState() => _LiveDetectionPageState();
}

class _LiveDetectionPageState extends State<LiveDetectionPage> {
  // --- Map & GPS ---
  final MapController _miniMapController = MapController();
  StreamSubscription<Position>? _positionStreamSubscription;
  double _currentSpeedMps = 0.0;

  // ── Extracted Services (Step 4) ──────────────────────────────────────────
  final PotholePhysicsService _physicsService = PotholePhysicsService();
  StreamSubscription<PotholeImpact>? _impactSubscription;

  // ── ValueNotifiers (Step 1) ──────────────────────────────────────────────
  final ValueNotifier<LatLng> _currentLocation = ValueNotifier(
    const LatLng(11.2588, 75.7804),
  );
  final ValueNotifier<int> _potholeCount = ValueNotifier(0);
  final ValueNotifier<int> _maxPotholesSession = ValueNotifier(0);
  final ValueNotifier<List<LatLng>> _detectedPotholeLocations = ValueNotifier(
    [],
  );

  // --- YOLO controller ---
  final YOLOViewController _yoloController = YOLOViewController();

  // --- MiDaS Capture Queue ---
  final List<CapturedPothole> _capturedPotholes = [];
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _captureCooldown = Duration(seconds: 5);
  bool _isProcessingDepth = false;
  bool _cameraGranted = false;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
    _startNavigationMode();

    // Enforce thresholds via controller
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _yoloController.setThresholds(
        confidenceThreshold: 0.86,
        iouThreshold: 0.30,
        numItemsThreshold: 10,
      );
    });

    // Start physics service and listen for impacts
    _physicsService.start();
    _impactSubscription = _physicsService.onImpact.listen(_onPhysicsImpact);
  }

  Future<void> _requestCameraPermission() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
    }
    if (mounted) {
      setState(() => _cameraGranted = status.isGranted);
    }
    if (!status.isGranted) {
      debugPrint('[PERMISSION] ❌ Camera permission denied');
    }
  }

  // ── GPS ─────────────────────────────────────────────────────────────────────
  void _startNavigationMode() {
    Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation,
        )
        .then((Position position) {
          _updateMapToFollowUser(LatLng(position.latitude, position.longitude));
          _currentSpeedMps = position.speed;
          _physicsService.currentSpeedMps = position.speed;
        })
        .catchError((e) {
          debugPrint('[GPS] ⚠️ Initial position fetch failed: $e');
        });

    _positionStreamSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
          ),
        ).listen((Position position) {
          _updateMapToFollowUser(LatLng(position.latitude, position.longitude));
          _currentSpeedMps = position.speed;
          _physicsService.currentSpeedMps = position.speed;
        });
  }

  void _updateMapToFollowUser(LatLng newPos) {
    if (!mounted) return;
    _currentLocation.value = newPos;
    _miniMapController.move(newPos, 17.0);
  }

  @override
  void dispose() {
    _yoloController.stop();
    _positionStreamSubscription?.cancel();
    _impactSubscription?.cancel();
    _physicsService.dispose();
    _miniMapController.dispose();
    _currentLocation.dispose();
    _potholeCount.dispose();
    _maxPotholesSession.dispose();
    _detectedPotholeLocations.dispose();
    super.dispose();
  }

  // ── PHYSICS IMPACT HANDLER ─────────────────────────────────────────────────
  Future<void> _onPhysicsImpact(PotholeImpact impact) async {
    final loc = _currentLocation.value;
    debugPrint(
      '[PHYSICS] 💥 Impact: ${impact.impact.toStringAsFixed(2)} m/s² '
      '→ severity=${impact.severity} at '
      '(${loc.latitude.toStringAsFixed(5)}, ${loc.longitude.toStringAsFixed(5)})',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Pothole Detected! Impact: ${impact.impact.toStringAsFixed(1)} m/s²",
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
        ),
      );
    }

    await PotholeRepository.savePhysicsDetection(
      lat: loc.latitude,
      lng: loc.longitude,
      severity: impact.severity,
      description:
          'Auto-detected: vertical pothole signature '
          '(impact: ${impact.impact.toStringAsFixed(2)} m/s², '
          'speed: ${(_currentSpeedMps * 3.6).toStringAsFixed(1)} km/h)',
    );
  }

  // ── STREAMING DATA HANDLER ──────────────────────────────────────────────────
  void _handleStreamingData(Map<String, dynamic> event) {
    final fps = event['fps'];
    final processingTimeMs = event['processingTimeMs'];
    if (fps != null || processingTimeMs != null) {
      debugPrint(
        '⚡ FPS: ${(fps as num?)?.toDouble().toStringAsFixed(1) ?? '?'} | '
        '⏱️ Inference: ${(processingTimeMs as num?)?.toDouble().toStringAsFixed(1) ?? '?'}ms',
      );
    }

    final detectionsData = event['detections'] as List<dynamic>? ?? [];
    final potholes = <Map<String, dynamic>>[];

    for (final detection in detectionsData) {
      if (detection is! Map) continue;
      final confidence = (detection['confidence'] as num?)?.toDouble() ?? 0.0;
      if (confidence > 0.85) {
        potholes.add(Map<String, dynamic>.from(detection));
      }
    }

    if (potholes.isNotEmpty) {
      final loc = _currentLocation.value;
      debugPrint(
        '${potholes.length} pothole(s) at '
        'Lat: ${loc.latitude}, Lng: ${loc.longitude}',
      );
    }

    // Update via ValueNotifier — NO setState
    _potholeCount.value = potholes.length;
    if (_potholeCount.value > _maxPotholesSession.value) {
      _maxPotholesSession.value = _potholeCount.value;
    }

    // Capture image for MiDaS if pothole detected
    if (potholes.isNotEmpty) {
      final now = DateTime.now();
      if (now.difference(_lastCaptureTime) < _captureCooldown) {
        debugPrint('⏳ Cooldown active, skipping capture');
        return;
      }
      _lastCaptureTime = now;

      final imageBytes = event['originalImage'];
      if (imageBytes == null) {
        debugPrint('⚠️ No original image in streaming data');
        return;
      }

      final bestDetection = potholes.reduce(
        (a, b) => (a['confidence'] as num) > (b['confidence'] as num) ? a : b,
      );

      final normalizedBoxMap = bestDetection['normalizedBox'] as Map?;
      if (normalizedBoxMap == null) {
        debugPrint('⚠️ No normalizedBox in detection');
        return;
      }

      final normalizedBox = Rect.fromLTRB(
        (normalizedBoxMap['left'] as num?)?.toDouble() ?? 0.0,
        (normalizedBoxMap['top'] as num?)?.toDouble() ?? 0.0,
        (normalizedBoxMap['right'] as num?)?.toDouble() ?? 0.0,
        (normalizedBoxMap['bottom'] as num?)?.toDouble() ?? 0.0,
      );

      final confidence =
          (bestDetection['confidence'] as num?)?.toDouble() ?? 0.0;

      final imageWidth = (event['imageWidth'] as num?)?.toInt() ?? 0;
      final imageHeight = (event['imageHeight'] as num?)?.toInt() ?? 0;

      _captureFrame(
        imageBytes is List<int> ? imageBytes : List<int>.from(imageBytes),
        normalizedBox,
        confidence,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
    }
  }

  Future<void> _captureFrame(
    List<int> imageBytes,
    Rect normalizedBox,
    double confidence, {
    int imageWidth = 0,
    int imageHeight = 0,
  }) async {
    print(
      '[CAPTURE] 📸 _captureFrame triggered! (conf: $confidence, bounds: $normalizedBox)',
    );
    try {
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final filePath = '${tempDir.path}/pothole_$timestamp.jpg';

      final params = _EncodeParams(
        imageBytes,
        width: imageWidth,
        height: imageHeight,
      );
      final encodedBytes = await compute(_encodeJpeg, params);
      await File(filePath).writeAsBytes(encodedBytes);
      print('[CAPTURE] 💾 Frame saved to temp path: $filePath');

      // Save to Supabase via PotholeRepository
      final loc = _currentLocation.value;
      final supabaseId = await PotholeRepository.saveYoloCapture(
        lat: loc.latitude,
        lng: loc.longitude,
        confidence: confidence,
      );

      if (supabaseId != null) {
        // Add to in-session mini-map markers via ValueNotifier
        _detectedPotholeLocations.value = [
          ..._detectedPotholeLocations.value,
          LatLng(loc.latitude, loc.longitude),
        ];
      }

      final capture = CapturedPothole(
        imagePath: filePath,
        normalizedBox: normalizedBox,
        lat: loc.latitude,
        lng: loc.longitude,
        confidence: confidence,
        supabaseId: supabaseId,
      );

      _capturedPotholes.add(capture);
      print(
        '[CAPTURE] ✅ Queued for MiDaS (queue: ${_capturedPotholes.length})',
      );
    } catch (e) {
      print('[CAPTURE] ❌ Failed to capture frame: $e');
    }
  }

  // ── SESSION END: Trigger MiDaS Pipeline ──────────────────────────────────────
  Future<void> _onSessionEnd() async {
    if (mounted) {
      setState(() => _isProcessingDepth = true);
    }

    await Future.delayed(const Duration(milliseconds: 300));

    print('[YOLO] 🛑 Stopping YOLO model...');
    try {
      await _yoloController.stop();
      print('[YOLO] 🛑 YOLO model stopped successfully');
    } catch (e) {
      print('[YOLO] ⚠️ Error stopping YOLO: $e');
    }

    await Future.delayed(const Duration(milliseconds: 500));

    print(
      '[YOLO] 📊 Session summary: ${_maxPotholesSession.value} max potholes, '
      '${_capturedPotholes.length} frames captured for MiDaS',
    );

    if (_capturedPotholes.isEmpty) {
      print('[MiDaS] 🔬 No captures to process in queue, exiting directly.');
      if (mounted) {
        setState(() => _isProcessingDepth = false);
        Navigator.pop(context, _maxPotholesSession.value);
      }
      return;
    }

    try {
      print(
        '[MiDaS] 🚀 Sending ${_capturedPotholes.length} captures to DepthSeverityService...',
      );
      final results = await DepthSeverityService.processQueue(
        List.from(_capturedPotholes),
      );

      print('[MiDaS] 🔬 Processed ${results.length} captures');
      for (final result in results) {
        print(
          '[MiDaS]    → ${result.severity} (dropoff: ${result.depthDropoff.toStringAsFixed(3)})',
        );
      }
    } catch (e) {
      print('[MiDaS] ❌ Pipeline error: $e');
    } finally {
      _capturedPotholes.clear();
      if (mounted) {
        setState(() => _isProcessingDepth = false);
        Navigator.pop(context, _maxPotholesSession.value);
      }
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (!_isProcessingDepth) _onSessionEnd();
      },
      child: Scaffold(
        body: Stack(
          children: [
            // 1. YOLOView
            if (_cameraGranted)
              YOLOView(
                modelPath: 'new-dataset-yolov26_int8',
                task: YOLOTask.detect,
                useGpu: false,
                streamingConfig: YOLOStreamingConfig.throttled(
                  maxFPS: 10,
                  includeMasks: false,
                  includeOriginalImage: true,
                ),
                controller: _yoloController,
                showOverlays: true,
                confidenceThreshold: 0.86,
                iouThreshold: 0.30,
                onStreamingData: _handleStreamingData,
              )
            else
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.camera_alt,
                      size: 64,
                      color: Colors.white54,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Camera permission required',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: () => openAppSettings(),
                      child: const Text('Open Settings'),
                    ),
                  ],
                ),
              ),

            // 2. LIVE indicator (top left)
            Positioned(
              top: 50,
              left: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.fiber_manual_record,
                      color: Colors.white,
                      size: 14,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'LIVE REC',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 3. Pothole count badge (top centre) — ValueListenableBuilder
            Positioned(
              top: 50,
              left: 0,
              right: 0,
              child: Center(
                child: ValueListenableBuilder<int>(
                  valueListenable: _potholeCount,
                  builder: (context, count, _) {
                    return ValueListenableBuilder<int>(
                      valueListenable: _maxPotholesSession,
                      builder: (context, maxSession, _) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: count > 0
                                ? Colors.deepOrange.withValues(alpha: 0.9)
                                : Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'Max Session: $maxSession  |  Current: $count',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),

            // 4. Capture queue indicator
            if (_capturedPotholes.isNotEmpty)
              Positioned(
                top: 95,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '📸 ${_capturedPotholes.length} frame(s) queued for depth analysis',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ),
              ),

            // 5. Mini Map (bottom right) — ValueListenableBuilder
            Positioned(
              bottom: 30,
              right: 20,
              child: Container(
                width: 130,
                height: 180,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ValueListenableBuilder<LatLng>(
                    valueListenable: _currentLocation,
                    builder: (context, loc, _) {
                      return FlutterMap(
                        mapController: _miniMapController,
                        options: MapOptions(
                          initialCenter: loc,
                          initialZoom: 17.0,
                          interactionOptions: const InteractionOptions(
                            flags: InteractiveFlag.none,
                          ),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.sajay.potholewatch',
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: loc,
                                width: 25,
                                height: 25,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.blueAccent,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 3,
                                    ),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Colors.black26,
                                        blurRadius: 4,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.navigation,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ValueListenableBuilder<List<LatLng>>(
                            valueListenable: _detectedPotholeLocations,
                            builder: (context, locs, _) {
                              return MarkerLayer(
                                markers: locs
                                    .map(
                                      (loc) => Marker(
                                        point: loc,
                                        width: 20,
                                        height: 20,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.deepOrange,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 2,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.warning_amber_rounded,
                                            color: Colors.white,
                                            size: 10,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              );
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),

            // 6. Close button (top right) — triggers MiDaS pipeline
            Positioned(
              top: 50,
              right: 20,
              child: CircleAvatar(
                backgroundColor: Colors.black54,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _isProcessingDepth ? null : _onSessionEnd,
                ),
              ),
            ),

            // 7. MiDaS processing overlay
            if (_isProcessingDepth)
              Container(
                color: Colors.black.withValues(alpha: 0.7),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.tealAccent),
                      const SizedBox(height: 20),
                      Text(
                        'Analyzing depth for ${_capturedPotholes.length} pothole(s)...',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Running MiDaS depth estimation',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
