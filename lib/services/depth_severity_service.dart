import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

import '../models/captured_pothole.dart';
import '../repositories/pothole_repository.dart';

class DepthSeverityService {
  /// ──────────────────────────────────────────────────────────────────────────
  ///  Toggle: set to `false` to run real MiDaS inference on device.
  /// ──────────────────────────────────────────────────────────────────────────
  static const bool _useMock = true;

  // ═══════════════════════════════════════════════════════════════════════════
  //  PUBLIC API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Process all queued captures. Switches between mock and real MiDaS
  /// based on the [_useMock] flag.
  static Future<List<SeverityResult>> processQueue(
    List<CapturedPothole> captures,
  ) async {
    if (captures.isEmpty) return [];

    final results = _useMock
        ? await _runMockPipeline(captures)
        : await _runRealPipeline(captures);

    // Update Supabase/Local repository for every result
    for (final result in results) {
      if (result.capture.supabaseId != null) {
        await PotholeRepository.updateSeverity(
          id: result.capture.supabaseId!,
          severity: result.severity,
          description:
              '${_useMock ? "MOCK" : "MiDaS"} depth analysis complete. '
              'Dropoff: ${result.depthDropoff.toStringAsFixed(3)}m → ${result.severity}',
        );
      }
    }

    debugPrint(
      '[DEPTH] ✅ Pipeline complete (${_useMock ? "MOCK" : "REAL"}). '
      'Processed ${results.length} frame(s).',
    );
    return results;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MOCK PIPELINE
  // ═══════════════════════════════════════════════════════════════════════════

  static final _random = Random();

  static Future<List<SeverityResult>> _runMockPipeline(
    List<CapturedPothole> captures,
  ) async {
    debugPrint(
      '[MiDaS-MOCK] Starting mock pipeline for ${captures.length} frame(s)...',
    );
    final results = <SeverityResult>[];

    for (int i = 0; i < captures.length; i++) {
      final capture = captures[i];
      debugPrint('[MiDaS-MOCK] ── Frame ${i + 1}/${captures.length} ──');

      // Simulate inference latency
      await Future.delayed(const Duration(milliseconds: 800));

      // Random dropoff between 0.05 m and 0.45 m
      final dropoff = 0.05 + _random.nextDouble() * 0.40;
      final severity = _classifySeverity(dropoff);

      debugPrint(
        '[MiDaS-MOCK] ✅ dropoff={dropoff.toStringAsFixed(3)}m → $severity',
      );

      results.add(
        SeverityResult(
          capture: capture,
          severity: severity,
          depthDropoff: dropoff,
        ),
      );
    }
    return results;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  REAL MiDaS PIPELINE (runs in a background Isolate)
  // ═══════════════════════════════════════════════════════════════════════════

  static Future<List<SeverityResult>> _runRealPipeline(
    List<CapturedPothole> captures,
  ) async {
    debugPrint('[MiDaS] Starting Isolate for real MiDaS Pipeline...');
    // Note: Isolate.run might need a serializable wrapper or use compute
    // if objects are complex, but SeverityResult/CapturedPothole are simple.
    return await Isolate.run(() => _midasIsolateEntry(captures));
  }

  static Future<List<SeverityResult>> _midasIsolateEntry(
    List<CapturedPothole> captures,
  ) async {
    final results = <SeverityResult>[];
    Interpreter? interpreter;

    try {
      interpreter = await Interpreter.fromAsset('assets/models/midas.tflite');

      for (int i = 0; i < captures.length; i++) {
        final capture = captures[i];
        final imageFile = File(capture.imagePath);
        if (!imageFile.existsSync()) continue;

        final originalImage = img.decodeImage(imageFile.readAsBytesSync());
        if (originalImage == null) continue;

        final resized = img.copyResize(originalImage, width: 256, height: 256);

        // Normalize
        final input = List.generate(
          1,
          (_) => List.generate(
            256,
            (y) => List.generate(256, (x) {
              final p = resized.getPixel(x, y);
              return [
                ((p.r.toDouble() / 255.0) - 0.485) / 0.229,
                ((p.g.toDouble() / 255.0) - 0.456) / 0.224,
                ((p.b.toDouble() / 255.0) - 0.406) / 0.225,
              ];
            }),
          ),
        );

        final output = List.generate(
          1,
          (_) => List.generate(
            256,
            (_) => List.generate(256, (_) => List.filled(1, 0.0)),
          ),
        );

        interpreter.run(input, output);
        final depthMap = output[0];

        // Basic severity math based on dropoff in the box
        final bx1 = (capture.normalizedBox.left * 256).clamp(0, 255).toInt();
        final by1 = (capture.normalizedBox.top * 256).clamp(0, 255).toInt();
        final bx2 = (capture.normalizedBox.right * 256).clamp(0, 255).toInt();
        final by2 = (capture.normalizedBox.bottom * 256).clamp(0, 255).toInt();

        double sumIn = 0;
        int cntIn = 0;
        for (int y = by1; y <= by2; y++) {
          for (int x = bx1; x <= bx2; x++) {
            sumIn += depthMap[y][x][0];
            cntIn++;
          }
        }
        final dIn = cntIn > 0 ? sumIn / cntIn : 0.0;

        // expanded ring for background
        final ex = ((bx2 - bx1) * 0.2).toInt();
        final ey = ((by2 - by1) * 0.2).toInt();
        final ox1 = (bx1 - ex).clamp(0, 255).toInt();
        final oy1 = (by1 - ey).clamp(0, 255).toInt();
        final ox2 = (bx2 + ex).clamp(0, 255).toInt();
        final oy2 = (by2 + ey).clamp(0, 255).toInt();

        double sumOut = 0;
        int cntOut = 0;
        for (int y = oy1; y <= oy2; y++) {
          for (int x = ox1; x <= ox2; x++) {
            if (x < bx1 || x > bx2 || y < by1 || y > by2) {
              sumOut += depthMap[y][x][0];
              cntOut++;
            }
          }
        }
        final dOut = cntOut > 0 ? sumOut / cntOut : dIn;
        final dropoff = dOut > 0 ? (dOut - dIn) / dOut : 0.0;
        final severity = _classifySeverity(dropoff);

        results.add(
          SeverityResult(
            capture: capture,
            severity: severity,
            depthDropoff: dropoff,
          ),
        );
      }
    } catch (e) {
      debugPrint('[MiDaS] Isolate Error: $e');
    } finally {
      interpreter?.close();
    }
    return results;
  }

  static String _classifySeverity(double dropoff) {
    if (dropoff > 0.35) return 'High';
    if (dropoff > 0.10) return 'Medium';
    return 'Low';
  }
}
