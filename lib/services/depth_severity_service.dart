import 'dart:io';
import 'dart:isolate';

import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

import '../models/captured_pothole.dart';
import '../repositories/pothole_repository.dart';

class DepthSeverityService {
  /// Process all queued captures with REAL MiDaS v2 Small depth analysis.
  static Future<List<SeverityResult>> processQueue(
    List<CapturedPothole> captures,
  ) async {
    if (captures.isEmpty) return [];

    print('[MiDaS] ═══════════════════════════════════════════');
    print('[MiDaS] Starting Isolate for MiDaS Pipeline...');

    // Midas Pipeline must happen inside a single isolate to prevent freezing UI.
    final results = await Isolate.run(() => _runMidasPipeline(captures));

    // Update Supabase from main thread via PotholeRepository
    for (final result in results) {
      if (result.capture.supabaseId != null) {
        await PotholeRepository.updateSeverity(
          id: result.capture.supabaseId!,
          severity: result.severity,
          description:
              'YOLO-detected pothole (conf: ${result.capture.confidence.toStringAsFixed(2)}). '
              'MiDaS depth dropoff: ${result.depthDropoff.toStringAsFixed(3)} → ${result.severity}',
        );
      }
    }

    print('[MiDaS] ');
    print('[MiDaS] ═══════════════════════════════════════════');
    print('[MiDaS] ✅ Pipeline complete. Processed ${results.length} frame(s).');
    print('[MiDaS] ═══════════════════════════════════════════');

    return results;
  }

  /// The Isolate function
  static Future<List<SeverityResult>> _runMidasPipeline(
    List<CapturedPothole> captures,
  ) async {
    final results = <SeverityResult>[];
    Interpreter? interpreter;

    try {
      print('[MiDaS] Initializing MiDaS v2 Small (256×256 float32)');
      interpreter = await Interpreter.fromAsset('assets/models/midas.tflite');
      print(
        '[MiDaS] Interpreter loaded from assets/models/midas.tflite inside isolate',
      );

      for (int i = 0; i < captures.length; i++) {
        final capture = captures[i];
        final frameNum = i + 1;

        print('[MiDaS] ');
        print('[MiDaS] ── Frame $frameNum/${captures.length} ──');
        print(
          '[MiDaS] Loading frame ${capture.imagePath.split('/').last} into memory...',
        );

        final File imageFile = File(capture.imagePath);
        if (!imageFile.existsSync()) {
          print('[MiDaS] ⚠️ Image file not found: ${capture.imagePath}');
          continue;
        }

        final imageBytes = imageFile.readAsBytesSync();
        final originalImage = img.decodeImage(imageBytes);

        if (originalImage == null) {
          print(
            '[MiDaS] ❌ Failed to decode image for capture ${capture.imagePath}',
          );
          continue;
        }

        print('[MiDaS] Resizing to 256x256...');
        final resizedImage = img.copyResize(
          originalImage,
          width: 256,
          height: 256,
        );

        print(
          '[MiDaS] Applying ImageNet Normalization to tensor shape [1, 256, 256, 3]',
        );

        // Prepare [1, 256, 256, 3] layout
        final inputData = List.generate(
          1,
          (_) => List.generate(
            256,
            (_) => List.generate(256, (_) => List.filled(3, 0.0)),
          ),
        );

        for (int y = 0; y < 256; y++) {
          for (int x = 0; x < 256; x++) {
            final pixel = resizedImage.getPixel(x, y);

            // For package:image ^4.x, pixel channels are num
            num r = pixel.r;
            num g = pixel.g;
            num b = pixel.b;

            // ImageNet Normalization: (val - mean) / std
            inputData[0][y][x][0] = ((r.toDouble() / 255.0) - 0.485) / 0.229;
            inputData[0][y][x][1] = ((g.toDouble() / 255.0) - 0.456) / 0.224;
            inputData[0][y][x][2] = ((b.toDouble() / 255.0) - 0.406) / 0.225;
          }
        }

        print('[MiDaS] Running inference on CPU...');

        // Output shape for MiDaS v2.1 Small must be exactly [1, 256, 256, 1]
        final outputData = List.generate(
          1,
          (_) => List.generate(
            256,
            (_) => List.generate(256, (_) => List.filled(1, 0.0)),
          ),
        );

        interpreter.run(inputData, outputData);

        print(
          '[MiDaS] Inference complete → depth map [1, 256, 256, 1] generated',
        );

        final depthMap = outputData[0]; // [256, 256, 1] matrix

        // Map the bounding box to depth map coords
        final bx1 = (capture.normalizedBox.left * 256).clamp(0, 255).toInt();
        final by1 = (capture.normalizedBox.top * 256).clamp(0, 255).toInt();
        final bx2 = (capture.normalizedBox.right * 256).clamp(0, 255).toInt();
        final by2 = (capture.normalizedBox.bottom * 256).clamp(0, 255).toInt();

        print(
          '[MiDaS] Mapping normalizedBox to depth map: ($bx1,$by1)→($bx2,$by2)',
        );

        // Calculate D_inside
        double sumInside = 0.0;
        int countInside = 0;

        for (int y = by1; y <= by2; y++) {
          for (int x = bx1; x <= bx2; x++) {
            sumInside += depthMap[y][x][0]; // Extract from [1] dim
            countInside++;
          }
        }
        final dInside = countInside > 0 ? sumInside / countInside : 0.0;

        // Calculate D_outside by expanding ring by 20%
        final boxW = bx2 - bx1;
        final boxH = by2 - by1;
        final expandX = (boxW * 0.2).toInt();
        final expandY = (boxH * 0.2).toInt();

        final ox1 = (bx1 - expandX).clamp(0, 255).toInt();
        final oy1 = (by1 - expandY).clamp(0, 255).toInt();
        final ox2 = (bx2 + expandX).clamp(0, 255).toInt();
        final oy2 = (by2 + expandY).clamp(0, 255).toInt();

        double sumOutside = 0.0;
        int countOutside = 0;

        for (int y = oy1; y <= oy2; y++) {
          for (int x = ox1; x <= ox2; x++) {
            // Include pixels in the expanded box but outside the original box
            if (x < bx1 || x > bx2 || y < by1 || y > by2) {
              sumOutside += depthMap[y][x][0]; // Extract from [1] dim
              countOutside++;
            }
          }
        }
        final dOutside = countOutside > 0 ? sumOutside / countOutside : dInside;

        // In MiDaS, higher values = closer, lower values = further away.
        // So a pothole (further away) will naturally have D_inside < D_outside.
        // Also note: the exact float magnitude varies greatly with ImageNet norm.
        final dropoff = dOutside > 0.0 ? (dOutside - dInside) / dOutside : 0.0;

        print('[MiDaS] Depth analysis complete:');
        print('[MiDaS]    D_inside  = ${dInside.toStringAsFixed(4)}');
        print('[MiDaS]    D_outside = ${dOutside.toStringAsFixed(4)}');
        print(
          '[MiDaS]    dropoff   = ${dropoff.toStringAsFixed(4)} (threshold: 0.10=High, 0.05=Medium)',
        );

        String severity;
        if (dropoff > 0.10) {
          severity = 'High';
        } else if (dropoff > 0.05) {
          severity = 'Medium';
        } else if (dropoff > 0.01) {
          severity = 'Low';
        } else {
          // If the inside is ACTUALLY higher than outside (bump, not a hole)
          // or flat, it's not severe at all.
          severity = 'Low';
        }

        print('[MiDaS] ✅ Frame $frameNum → severity=$severity');

        results.add(
          SeverityResult(
            capture: capture,
            severity: severity,
            depthDropoff: dropoff,
          ),
        );
      }

      // Cleanup files directly after isolate finished with them
      for (final capture in captures) {
        try {
          final f = File(capture.imagePath);
          if (f.existsSync()) {
            f.deleteSync();
          }
        } catch (_) {}
      }
    } catch (e, st) {
      print('[MiDaS] ❌ Pipeline error in isolate: $e');
      print('[MiDaS] Stacktrace: $st');
    } finally {
      // Explicitly clean up interpreter memory
      if (interpreter != null) {
        interpreter.close();
        print('[MiDaS] Interpreter closed. Memory freed in Isolate.');
      }
    }

    return results;
  }
}
