import 'package:sqflite/sqflite.dart';
import '../models/set_entry.dart';

class SetsDao {
  final Database _db;

  SetsDao(this._db);

  Future<int> insert(SetEntry s, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    return db.insert('sets', s.toMap());
  }

  Future<void> update(SetEntry s, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    await db.update(
      'sets',
      s.toMap(),
      where: 'id = ?',
      whereArgs: [s.id],
    );
  }

  Future<void> updateTransaction(List<SetEntry> sets) async {
    await _db.transaction((txn) async {
      for (final s in sets) {
        if (s.id == null) continue;
        await txn.update(
          'sets',
          s.toMap(),
          where: 'id = ?',
          whereArgs: [s.id],
        );
      }
    });
  }

  Future<void> delete(int id, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    await db.delete('sets', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAndRenumber(int setId, int sessionExerciseId, {DatabaseExecutor? executor}) async {
    Future<void> action(DatabaseExecutor txn) async {
      await txn.delete('sets', where: 'id = ?', whereArgs: [setId]);

      final rows = await txn.query(
        'sets',
        where: 'session_exercise_id = ?',
        whereArgs: [sessionExerciseId],
        orderBy: 'set_number ASC',
      );

      for (int i = 0; i < rows.length; i++) {
        final id = rows[i]['id'];
        await txn.update(
          'sets',
          {'set_number': i + 1},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
    }

    if (executor is Transaction) {
      await action(executor);
    } else {
      await _db.transaction(action);
    }
  }

  Future<List<SetEntry>> getForSessionExercise(int sessionExerciseId, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    final rows = await db.query(
      'sets',
      where: 'session_exercise_id = ?',
      whereArgs: [sessionExerciseId],
      orderBy: 'set_number ASC',
    );
    return rows.map(SetEntry.fromMap).toList();
  }

  Future<List<SetEntry>> getLastSetsForExercise(int exerciseId, {int limit = 10, DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    final rows = await db.rawQuery('''
      SELECT s.* FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN workout_sessions ws ON ws.id = se.session_id
      WHERE se.exercise_id = ? AND ws.ended_at IS NOT NULL
      ORDER BY ws.started_at DESC, s.set_number ASC
      LIMIT ?
    ''', [exerciseId, limit]);
    return rows.map(SetEntry.fromMap).toList();
  }

  Future<List<SetEntry>> getSetsFromLastCompletedSession(int exerciseId, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    final rows = await db.rawQuery('''
      SELECT s.* FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN workout_sessions ws ON ws.id = se.session_id
      WHERE se.session_id = (
        SELECT ws2.id FROM workout_sessions ws2
        JOIN session_exercises se2 ON se2.session_id = ws2.id
        JOIN sets s2 ON s2.session_exercise_id = se2.id
        WHERE se2.exercise_id = ? AND ws2.ended_at IS NOT NULL AND s2.is_completed = 1
        ORDER BY ws2.started_at DESC
        LIMIT 1
      ) AND se.exercise_id = ?
        -- HISTORY FIX: Only return completed, non-warmup sets.
        -- The outer query must filter to completed working sets so that
        -- positional mapping (prevSets[setIndex]) is correct.
        -- Without this: warmup sets shift the index, causing working set N
        -- to show warmup weight/reps as its hint in the input fields.
        -- Uncompleted ghost sets from previous sessions are also excluded.
        AND s.is_completed = 1
        AND s.set_type != 'warmup'
      ORDER BY s.set_number ASC
    ''', [exerciseId, exerciseId]);
    return rows.map(SetEntry.fromMap).toList();
  }

  Future<double> getPersonalBestWeight(int exerciseId, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    final res = await db.rawQuery('''
      SELECT MAX(weight_kg) as max_weight FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN workout_sessions ws ON ws.id = se.session_id
      WHERE se.exercise_id = ? 
        AND ws.ended_at IS NOT NULL 
        AND s.is_completed = 1
        AND s.set_type != 'warmup'
    ''', [exerciseId]);

    final val = res.first['max_weight'];
    if (val == null) return 0.0;
    return (val as num).toDouble();
  }

  Future<double> getPersonalBestE1RM(int exerciseId, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    final res = await db.rawQuery('''
      SELECT MAX(s.weight_kg * (36.0 / (37.0 - CASE WHEN s.reps > 36 THEN 36 ELSE s.reps END))) as max_e1rm 
      FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN workout_sessions ws ON ws.id = se.session_id
      WHERE se.exercise_id = ? 
        AND ws.ended_at IS NOT NULL 
        AND s.is_completed = 1
        AND s.set_type != 'warmup'
        AND s.reps IS NOT NULL AND s.reps > 0
    ''', [exerciseId]);

    final val = res.first['max_e1rm'];
    if (val == null) return 0.0;
    return (val as num).toDouble();
  }

  Future<({double weight, double e1rm, double volume})> getBestBenchmarksBefore(
      int exerciseId, String beforeDateIso, {DatabaseExecutor? executor}) async {
    final db = executor ?? _db;
    final res = await db.rawQuery('''
      SELECT 
        MAX(s.weight_kg) as max_weight,
        MAX(s.weight_kg * (36.0 / (37.0 - CASE WHEN s.reps > 36 THEN 36 ELSE s.reps END))) as max_e1rm,
        MAX(s.weight_kg * s.reps) as max_volume
      FROM sets s
      JOIN session_exercises se ON se.id = s.session_exercise_id
      JOIN workout_sessions ws ON ws.id = se.session_id
      WHERE se.exercise_id = ? 
        AND ws.started_at < ?
        AND ws.ended_at IS NOT NULL 
        AND s.is_completed = 1
        AND s.set_type != 'warmup'
        AND s.reps IS NOT NULL AND s.reps > 0
    ''', [exerciseId, beforeDateIso]);

    if (res.isEmpty) return (weight: 0.0, e1rm: 0.0, volume: 0.0);
    
    final r = res.first;
    return (
      weight: (r['max_weight'] as num?)?.toDouble() ?? 0.0,
      e1rm: (r['max_e1rm'] as num?)?.toDouble() ?? 0.0,
      volume: (r['max_volume'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
