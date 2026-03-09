import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Offline-first repository for all pothole CRUD operations.
///
/// Writes go to a local SQLite queue first, then sync to Supabase when online.
/// This ensures no data is lost if the device is on the road without signal.
class PotholeRepository {
  static Database? _db;
  static final _supabase = Supabase.instance.client;
  static StreamSubscription? _connectivitySub;

  // ── Initialisation ──────────────────────────────────────────────────────────
  static Future<Database> _getDb() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'pothole_queue.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pothole_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            severity TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'Pending',
            description TEXT NOT NULL,
            supabase_id TEXT,
            synced INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
          )
        ''');
        debugPrint('[REPO] 🗃️ SQLite pothole_queue table created');
      },
    );
    return _db!;
  }

  /// Call once at app startup — syncs any pending records and starts listening
  /// for connectivity changes.
  static Future<void> init() async {
    await _getDb();
    await syncPending();

    _connectivitySub = Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      // If any result is NOT 'none', we have connectivity
      if (results.any((r) => r != ConnectivityResult.none)) {
        debugPrint('[REPO] 🌐 Connectivity restored — syncing pending...');
        syncPending();
      }
    });
  }

  /// Dispose the connectivity listener.
  static void dispose() {
    _connectivitySub?.cancel();
  }

  // ── Write operations (offline-first) ────────────────────────────────────────

  /// Save a physics-detected pothole. Returns the local SQLite row ID.
  static Future<String?> savePhysicsDetection({
    required double lat,
    required double lng,
    required String severity,
    required String description,
  }) async {
    return _saveLocal(
      lat: lat,
      lng: lng,
      severity: severity,
      description: description,
    );
  }

  /// Save a YOLO-captured pothole with 'Pending' severity.
  /// Returns the Supabase row ID if sync succeeded, or the local ID as
  /// fallback.
  static Future<String?> saveYoloCapture({
    required double lat,
    required double lng,
    required double confidence,
  }) async {
    return _saveLocal(
      lat: lat,
      lng: lng,
      severity: 'Pending',
      description:
          'YOLO-detected pothole (confidence: ${confidence.toStringAsFixed(2)}). Depth analysis queued.',
    );
  }

  /// Core local insert + opportunistic Supabase sync.
  static Future<String?> _saveLocal({
    required double lat,
    required double lng,
    required String severity,
    required String description,
  }) async {
    final db = await _getDb();

    // 1. Insert locally first
    final localId = await db.insert('pothole_queue', {
      'lat': lat,
      'lng': lng,
      'severity': severity,
      'status': 'Pending',
      'description': description,
      'synced': 0,
    });
    debugPrint('[REPO] 💾 Saved locally (localId: $localId)');

    // 2. Attempt immediate Supabase sync
    try {
      final response = await _supabase
          .from('potholes')
          .insert({
            'lat': lat,
            'lng': lng,
            'severity': severity,
            'status': 'Pending',
            'description': description,
          })
          .select('id')
          .single();

      final supabaseId = response['id']?.toString();
      if (supabaseId != null) {
        await db.update(
          'pothole_queue',
          {'synced': 1, 'supabase_id': supabaseId},
          where: 'id = ?',
          whereArgs: [localId],
        );
        debugPrint('[REPO] ☁️ Immediately synced → Supabase ID: $supabaseId');
        return supabaseId;
      }
    } catch (e) {
      debugPrint('[REPO] ⚠️ Immediate sync failed (will retry): $e');
    }

    // Return local ID as string if Supabase sync failed
    return 'local_$localId';
  }

  /// Update an existing pothole record with MiDaS severity results.
  /// Handles both Supabase IDs and local IDs.
  static Future<void> updateSeverity({
    required String id,
    required String severity,
    required String description,
  }) async {
    // If it's a local-only record, just update SQLite
    if (id.startsWith('local_')) {
      final localId = int.tryParse(id.replaceFirst('local_', ''));
      if (localId != null) {
        final db = await _getDb();
        await db.update(
          'pothole_queue',
          {'severity': severity, 'description': description},
          where: 'id = ?',
          whereArgs: [localId],
        );
        debugPrint('[REPO] 💾 Severity updated locally → $severity (ID: $id)');
      }
      return;
    }

    // Otherwise update Supabase directly
    try {
      await _supabase
          .from('potholes')
          .update({'severity': severity, 'description': description})
          .eq('id', id);
      debugPrint('[REPO] ✅ Severity updated → $severity (ID: $id)');
    } catch (e) {
      debugPrint('[REPO] ❌ Severity update failed for $id: $e');
    }
  }

  // ── Sync logic ──────────────────────────────────────────────────────────────

  /// Push all locally-queued, unsynced records to Supabase.
  static Future<void> syncPending() async {
    final db = await _getDb();
    final pending = await db.query(
      'pothole_queue',
      where: 'synced = 0',
      orderBy: 'id ASC',
    );

    if (pending.isEmpty) {
      debugPrint('[REPO] 🔄 No pending records to sync.');
      return;
    }

    debugPrint('[REPO] 🔄 Syncing ${pending.length} pending record(s)...');

    int synced = 0;
    for (final row in pending) {
      try {
        final response = await _supabase
            .from('potholes')
            .insert({
              'lat': row['lat'],
              'lng': row['lng'],
              'severity': row['severity'],
              'status': row['status'],
              'description': row['description'],
            })
            .select('id')
            .single();

        final supabaseId = response['id']?.toString();
        if (supabaseId != null) {
          await db.update(
            'pothole_queue',
            {'synced': 1, 'supabase_id': supabaseId},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          synced++;
        }
      } catch (e) {
        debugPrint('[REPO] ⚠️ Sync failed for localId ${row['id']}: $e');
        // Stop trying if we hit a network error — remaining will also fail
        break;
      }
    }

    debugPrint('[REPO] ✅ Synced $synced/${pending.length} records.');
  }
}
