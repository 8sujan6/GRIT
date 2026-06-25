import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dao_providers.dart';
import 'database_provider.dart';
import 'profile_provider.dart';
import 'workout_timer_provider.dart';
import 'dashboard_provider.dart';
import 'metrics_provider.dart';
import '../data/models/exercise.dart';
import '../data/models/routine.dart';
import '../data/models/workout_session.dart';
import '../data/models/session_exercise.dart';
import '../data/models/set_entry.dart';
import '../core/utils/workout_utils.dart';
import '../core/utils/haptics.dart';
import '../services/wakelock_service.dart';
import '../features/workout/workout_notification_manager.dart';
import '../features/workout/workout_persistence_manager.dart';
import '../features/workout/workout_session_manager.dart';
import '../services/notification_service.dart';

class ActiveWorkoutState {
  final WorkoutSession? session;
  final Routine? previewRoutine;
  final List<SessionExercise> exercises;
  final Map<int, List<SetEntry>> sets; // sessionExerciseId -> List<SetEntry>
  final Map<int, List<SetEntry>> previousSets; // exerciseId -> List<SetEntry> from last completed session
  final Map<int, Exercise> exerciseDetails; // exerciseId -> Exercise
  final Map<int, double> bestWeights; // exerciseId -> bestWeight
  final Map<int, double> bestE1RMs; // exerciseId -> bestE1RM
  final Map<int, double> bestSetVolumes; // exerciseId -> bestSetVolume
  final bool isLoading;
  final String? error;
  final bool isProcessing;
  final int? restingExerciseIndex;
  final bool autoRestEnabled;
  final int? sessionRestOverride;
  final Set<int> lockedExerciseIds; // Set of sessionExerciseId that are locked

  const ActiveWorkoutState({
    this.session,
    this.previewRoutine,
    this.exercises = const [],
    this.sets = const {},
    this.previousSets = const {},
    this.exerciseDetails = const {},
    this.bestWeights = const {},
    this.bestE1RMs = const {},
    this.bestSetVolumes = const {},
    this.isLoading = false,
    this.isProcessing = false,
    this.error,
    this.restingExerciseIndex,
    this.autoRestEnabled = true,
    this.sessionRestOverride,
    this.lockedExerciseIds = const {},
  });

  bool get hasActiveSession => session != null;
  bool get isPreview => session == null && previewRoutine != null;

  ActiveWorkoutState copyWith({
    WorkoutSession? session,
    List<SessionExercise>? exercises,
    Map<int, List<SetEntry>>? sets,
    Map<int, List<SetEntry>>? previousSets,
    Map<int, Exercise>? exerciseDetails,
    Map<int, double>? bestWeights,
    Map<int, double>? bestE1RMs,
    Map<int, double>? bestSetVolumes,
    bool? isLoading,
    bool? isProcessing,
    String? error,
    int? restingExerciseIndex,
    bool? autoRestEnabled,
    int? sessionRestOverride,
    bool clearError = false,
    Routine? previewRoutine,
    bool clearPreview = false,
    Set<int>? lockedExerciseIds,
  }) =>
      ActiveWorkoutState(
        session: session ?? this.session,
        previewRoutine:
            clearPreview ? null : previewRoutine ?? this.previewRoutine,
        exercises: exercises ?? this.exercises,
        sets: sets ?? this.sets,
        previousSets: previousSets ?? this.previousSets,
        exerciseDetails: exerciseDetails ?? this.exerciseDetails,
        bestWeights: bestWeights ?? this.bestWeights,
        bestE1RMs: bestE1RMs ?? this.bestE1RMs,
        bestSetVolumes: bestSetVolumes ?? this.bestSetVolumes,
        isLoading: isLoading ?? this.isLoading,
        isProcessing: isProcessing ?? this.isProcessing,
        error: clearError ? null : error ?? this.error,
        restingExerciseIndex: restingExerciseIndex ?? this.restingExerciseIndex,
        autoRestEnabled: autoRestEnabled ?? this.autoRestEnabled,
        sessionRestOverride: sessionRestOverride ?? this.sessionRestOverride,
        lockedExerciseIds: lockedExerciseIds ?? this.lockedExerciseIds,
      );
}

class ActiveWorkoutNotifier extends Notifier<ActiveWorkoutState>
    with WidgetsBindingObserver {
  final Map<int, Timer> _setDebouncers = {};
  StreamSubscription? _notificationSubscription;
  Timer? _inactivityTimer;

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(const Duration(minutes: 15), () async {
      debugPrint('GRIT: Inactivity timeout reached (15m). Disabling wakelock.');
      await GritWakelock.disable();
      state = state.copyWith(error: 'SCREEN WAKELOCK DISABLED DUE TO INACTIVITY.');
      Timer(const Duration(seconds: 5), () {
        if (state.error == 'SCREEN WAKELOCK DISABLED DUE TO INACTIVITY.') {
          state = state.copyWith(clearError: true);
        }
      });
    });
  }

  @override
  ActiveWorkoutState build() {
    WidgetsBinding.instance.addObserver(this);

    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _notificationSubscription?.cancel();
      _flushPendingSets();
      _setDebouncers.clear();
      _inactivityTimer?.cancel();
      GritWakelock.disable();
    });

    // Handle rest timer completion to clear index
    ref.listen(workoutTimerProvider, (previous, next) {
      if (previous?.restSecondsRemaining != null &&
          next.restSecondsRemaining == null) {
        if (state.restingExerciseIndex != null) {
          state = state.copyWith(restingExerciseIndex: null);
          _updateNotification();
        }
      }
    });

    _initNotificationListener();
    _loadActiveSession();
    return const ActiveWorkoutState(isLoading: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flushPendingSets();
    }
  }

  void _flushPendingSets() {
    try {
      final profile = ref.read(profileProvider);
      final setDao = ref.read(setsDaoProvider);
      final sessionsDao = ref.read(sessionsDaoProvider);

      WorkoutPersistenceManager.flushPendingSets(
        debouncers: _setDebouncers,
        setsMap: state.sets,
        exercises: state.exercises,
        exerciseDetails: state.exerciseDetails,
        session: state.session,
        profile: profile,
        setDao: setDao,
        sessionsDao: sessionsDao,
      ).ignore();
    } catch (e) {
      debugPrint('GRIT: Could not flush pending sets (container may be disposed): $e');
    }
  }

  void _initNotificationListener() {
    _notificationSubscription?.cancel();
    _notificationSubscription =
        NotificationService().actionStream.listen(_handleNotificationAction);
  }

  void _handleNotificationAction(String action) {
    if (state.session == null) return;

    switch (action) {
      case 'log_set':
        _logCurrentPendingSet();
        break;
      case 'skip_rest':
        skipRest();
        break;
      case 'finish_workout':
        finishWorkout();
        break;
    }
  }

  Future<void> _logCurrentPendingSet() async {
    // Logic to find the current active set and log it
    for (int i = 0; i < state.exercises.length; i++) {
      final se = state.exercises[i];
      final sets = state.sets[se.id] ?? [];
      final idx = sets.indexWhere((s) => !s.isCompleted);
      if (idx != -1) {
        await completeSet(i, idx);
        break;
      }
    }
  }

  Future<void> _loadActiveSession() async {
    try {
      await ref.read(databaseProvider.future);

      final result = await WorkoutSessionManager.loadActiveSession(
        sessionsDao: ref.read(sessionsDaoProvider),
        exercisesDao: ref.read(exercisesDaoProvider),
        setsDao: ref.read(setsDaoProvider),
      );

      if (result.session == null) {
        state = const ActiveWorkoutState();
        return;
      }

      await GritWakelock.enable();

      final currentSession = result.session;
      if (currentSession != null) {
        ref.read(workoutTimerProvider.notifier).updateWorkoutInfo(
              startedAt: DateTime.parse(currentSession.startedAt),
              sessionName: currentSession.name,
            );
      }

      final previousSetsMap = <int, List<SetEntry>>{};
      final setsDao = ref.read(setsDaoProvider);
      for (final se in result.exercises) {
        if (!previousSetsMap.containsKey(se.exerciseId)) {
          final pSets = await setsDao.getSetsFromLastCompletedSession(se.exerciseId);
          previousSetsMap[se.exerciseId] = pSets;
        }
      }

      state = ActiveWorkoutState(
        session: result.session,
        exercises: result.exercises,
        sets: result.sets,
        previousSets: previousSetsMap,
        exerciseDetails: result.exerciseDetails,
        bestWeights: result.bestWeights,
        bestE1RMs: result.bestE1RMs,
        bestSetVolumes: result.bestSetVolumes,
      );

      _updateNotification();
      _resetInactivityTimer();
    } catch (e, stack) {
      debugPrint('GRIT ERROR: Failed to load active session: $e');
      debugPrint('GRIT ERROR: Stack: $stack');
      state = ActiveWorkoutState(
          error: 'Failed to synchronize workout data: ${e.toString()}');
    }
  }

  Future<void> loadRoutineForPreview(int routineId) async {
    state = state.copyWith(isLoading: true, clearPreview: true);
    try {
      final rDao = ref.read(routinesDaoProvider);

      final routine = await rDao.getById(routineId);
      if (routine == null) {
        state = state.copyWith(isLoading: false);
        return;
      }

      final result = await WorkoutSessionManager.loadRoutinePreview(
        routine: routine,
        setsDao: ref.read(setsDaoProvider),
      );

      state = state.copyWith(
        isLoading: false,
        previewRoutine: routine,
        exercises: result.exercises,
        exerciseDetails: result.exerciseDetails,
        sets: result.sets,
        previousSets: result.previousSets,
        bestWeights: result.bestWeights,
        bestE1RMs: result.bestE1RMs,
        bestSetVolumes: result.bestSetVolumes,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> startWorkout(int routineId) async {
    if (state.isLoading) return;

    // Request notification permissions
    await NotificationService().requestPermissions();

    state = state.copyWith(isLoading: true, clearPreview: true);
    final rDao = ref.read(routinesDaoProvider);

    final routine = await rDao.getById(routineId);
    if (routine == null) {
      state = state.copyWith(error: "ROUTINE NOT FOUND");
      return;
    }

    try {
      final db = await ref.read(databaseProvider.future);
      final profile = ref.read(profileProvider);

      final result = await WorkoutSessionManager.startWorkout(
        routineId: routineId,
        name: routine.name,
        routineExercises: routine.exercises ?? [],
        userBodyweightKg: profile.weightKg,
        db: db,
        sessionsDao: ref.read(sessionsDaoProvider),
        setsDao: ref.read(setsDaoProvider),
      );

      final previousSetsMap = <int, List<SetEntry>>{};
      final setsDao = ref.read(setsDaoProvider);
      for (final se in result.exercises) {
        if (!previousSetsMap.containsKey(se.exerciseId)) {
          final pSets = await setsDao.getSetsFromLastCompletedSession(se.exerciseId);
          previousSetsMap[se.exerciseId] = pSets;
        }
      }

      state = ActiveWorkoutState(
        session: result.session,
        exercises: result.exercises,
        sets: result.sets,
        previousSets: previousSetsMap,
        exerciseDetails: result.exerciseDetails,
      );

      GritHaptics.workoutStart();
      await GritWakelock.enable();
      
      final currentSession = state.session;
      if (currentSession != null) {
        ref.read(workoutTimerProvider.notifier).startElapsedTimer(
              DateTime.parse(currentSession.startedAt),
              sessionName: routine.name,
            );
      }

      _updateNotification();
      _resetInactivityTimer();
      Future.microtask(() => ref.invalidate(dashboardDataProvider));
    } catch (e) {
      debugPrint('GRIT ERROR: Failed to start transactionally: $e');
      state =
          state.copyWith(error: 'Failed to initialize workout session safely.', isLoading: false);
    }
  }

  Future<void> addSet(int exerciseIndex) async {
    _resetInactivityTimer();
    if (state.isProcessing) return;
    if (exerciseIndex < 0 || exerciseIndex >= state.exercises.length) return;

    state = state.copyWith(isProcessing: true);
    final se = state.exercises[exerciseIndex];
    final sessionExerciseId = se.id!;

    final setDao = ref.read(setsDaoProvider);
    final currentSets = state.sets[sessionExerciseId] ?? [];
    final lastSet = currentSets.isNotEmpty ? currentSets.last : null;

    final newSet = SetEntry(
      sessionExerciseId: sessionExerciseId,
      setNumber: currentSets.length + 1,
      weightKg: lastSet?.weightKg ?? 0.0,
      reps: lastSet?.reps,
      loggedAt: DateTime.now().toIso8601String(),
    );

    try {
      final id = await setDao.insert(newSet);
      final setWithId = newSet.copyWith(id: id);

      // ANTI-RACE: Read current state AFTER await
      final updatedSets = Map<int, List<SetEntry>>.from(state.sets);
      final realCurrentSets = updatedSets[sessionExerciseId] ?? [];
      updatedSets[sessionExerciseId] = [...realCurrentSets, setWithId];

      state = state.copyWith(sets: updatedSets);
      GritHaptics.addSet();
      _updateNotification();
    } catch (e) {
      debugPrint('GRIT ERROR: Failed to add set: $e');
      state = state.copyWith(error: 'Failed to add set.');
    } finally {
      state = state.copyWith(isProcessing: false);
    }
  }

  Future<void> deleteSet(int exerciseIndex, int setIndex) async {
    _resetInactivityTimer();
    if (state.isProcessing) return;
    if (exerciseIndex < 0 || exerciseIndex >= state.exercises.length) return;
    
    state = state.copyWith(isProcessing: true);
    final se = state.exercises[exerciseIndex];
    final currentSets = state.sets[se.id!] ?? [];
    if (setIndex < 0 || setIndex >= currentSets.length) return;

    final setToDelete = currentSets[setIndex];
    if (setToDelete.id == null) return;

    try {
      // Remove from DB first - DAO handles renumbering
      await ref.read(setsDaoProvider).deleteAndRenumber(setToDelete.id!, se.id!);

      // Refresh state from DB to ensure absolute consistency
      final updatedSetList =
          await ref.read(setsDaoProvider).getForSessionExercise(se.id!);

      final updatedSets = Map<int, List<SetEntry>>.from(state.sets);
      updatedSets[se.id!] = updatedSetList;

      state = state.copyWith(sets: updatedSets);
      _updateNotification();
      GritHaptics.lightImpact();
    } catch (e) {
      debugPrint('GRIT ERROR: Failed to delete set: $e');
      state = state.copyWith(error: 'Failed to delete set.');
    } finally {
      state = state.copyWith(isProcessing: false);
    }
  }

  void updateSet(SetEntry updatedSet) {
    _resetInactivityTimer();
    if (updatedSet.id == null) return;

    final updatedSets = Map<int, List<SetEntry>>.from(state.sets);
    final list =
        List<SetEntry>.from(updatedSets[updatedSet.sessionExerciseId] ?? []);
    final index = list.indexWhere((s) => s.id == updatedSet.id);
    if (index != -1) {
      list[index] = updatedSet;
      updatedSets[updatedSet.sessionExerciseId] = list;
      state = state.copyWith(sets: updatedSets);
      _updateNotification();

      _setDebouncers[updatedSet.id!]?.cancel();
      _setDebouncers[updatedSet.id!] =
          Timer(const Duration(milliseconds: 500), () async {
        try {
          // ANTI-RACE: Re-read the set from current state to ensure we don't overwrite
          // a "Completed" flag with a stale "Uncompleted" flag from the debouncer.
          final currentSetList = state.sets[updatedSet.sessionExerciseId];
          final currentSet =
              currentSetList?.firstWhere((s) => s.id == updatedSet.id);

          if (currentSet != null) {
            final se = state.exercises
                .firstWhere((e) => e.id == updatedSet.sessionExerciseId);
            final profile = ref.read(profileProvider);

            // PR RE-EVALUATION: If the set is completed, we must re-evaluate PR status
            // to avoid "Ghost PRs" after a user lowers the weight/reps.
            bool isPr = currentSet.isPr;
            if (currentSet.isCompleted) {
              final bestWeight = state.bestWeights[se.exerciseId] ?? 0.0;
              final bestE1RM = state.bestE1RMs[se.exerciseId] ?? 0.0;
              final bestVolume = state.bestSetVolumes[se.exerciseId] ?? 0.0;
              final exType =
                  state.exerciseDetails[se.exerciseId]?.type ?? 'weighted';

              isPr = WorkoutUtils.isPersonalRecord(
                currentSet,
                bestWeightBefore: bestWeight,
                bestE1RMBefore: bestE1RM,
                bestSetVolumeBefore: bestVolume,
                exerciseType: exType,
                userBodyweight: profile.weightKg,
              );
            }

            final finalizedSet = currentSet.copyWith(isPr: isPr);
            await ref.read(setsDaoProvider).update(finalizedSet);

            // ANTI-DATA-LOSS: Incrementally update session volume
            final exTypesMap = {
              for (final se in state.exercises)
                se.id!: state.exerciseDetails[se.exerciseId]?.type ?? 'weighted'
            };
            final cumulativeVolume = WorkoutUtils.calculateTotalVolume(
                state.sets, exTypesMap, profile.weightKg);
            final session = state.session;
            if (session != null && session.id != null) {
              await ref
                  .read(sessionsDaoProvider)
                  .updateSessionVolume(session.id!, cumulativeVolume);
            }

            // Sync state if PR status changed during background update
            if (isPr != currentSet.isPr) {
              final updatedSetsMap = Map<int, List<SetEntry>>.from(state.sets);
              final updatedList = List<SetEntry>.from(
                  updatedSetsMap[updatedSet.sessionExerciseId]!);
              final idx = updatedList.indexWhere((s) => s.id == updatedSet.id);
              if (idx != -1) {
                updatedList[idx] = finalizedSet;
                updatedSetsMap[updatedSet.sessionExerciseId] = updatedList;
                state = state.copyWith(sets: updatedSetsMap);
              }
            }
          }

          _setDebouncers.remove(updatedSet.id);
        } catch (e) {
          debugPrint('Error updating set: $e');
        }
      });
    }
  }

  Future<void> addExercises(List<Exercise> details) async {
    _resetInactivityTimer();
    if (state.session == null || details.isEmpty) return;
    final sDao = ref.read(sessionsDaoProvider);
    final setDao = ref.read(setsDaoProvider);

    final addedExercises = <SessionExercise>[];
    final addedDetails = <int, Exercise>{};
    final addedBestWeights = <int, double>{};
    final addedBestE1RMs = <int, double>{};
    final addedBestSetVolumes = <int, double>{};
    final addedSets = <int, List<SetEntry>>{};

    final session = state.session;
    if (session == null || session.id == null) return;

    try {
      final db = await ref.read(databaseProvider.future);
      await db.transaction((txn) async {
        for (final detail in details) {
          final se = SessionExercise(
            sessionId: session.id!,
            exerciseId: detail.id!,
            orderIndex: state.exercises.length + addedExercises.length,
            targetSets: 1,
            targetReps: '8-12',
            targetRest: 90,
          );

          final seId = await sDao.insertExercise(se, executor: txn);
          final seWithId = se.copyWith(id: seId, exercise: detail);
          addedExercises.add(seWithId);

          final newSet = SetEntry(
            sessionExerciseId: seId,
            setNumber: 1,
            weightKg: 0.0,
            reps: null,
            loggedAt: DateTime.now().toIso8601String(),
          );
          final setId = await setDao.insert(newSet, executor: txn);
          final setWithId = newSet.copyWith(id: setId);

          addedDetails[detail.id!] = detail;
          addedSets[seId] = [setWithId];
        }
      });

      final addedPreviousSets = <int, List<SetEntry>>{};
      for (final detail in details) {
        final pSets = await setDao.getSetsFromLastCompletedSession(detail.id!);
        addedPreviousSets[detail.id!] = pSets;
      }

      // ANTI-RACE: Read state again before assigning to merge with any updates during DB calls
      state = state.copyWith(
        exercises: [...state.exercises, ...addedExercises],
        exerciseDetails: {...state.exerciseDetails, ...addedDetails},
        bestWeights: {...state.bestWeights, ...addedBestWeights},
        bestE1RMs: {...state.bestE1RMs, ...addedBestE1RMs},
        bestSetVolumes: {...state.bestSetVolumes, ...addedBestSetVolumes},
        sets: {...state.sets, ...addedSets},
        previousSets: {...state.previousSets, ...addedPreviousSets},
      );

      GritHaptics.addExercise();
      _updateNotification();
    } catch (e) {
      debugPrint('GRIT ERROR: Failed to add exercises: $e');
      state = state.copyWith(error: 'Failed to add exercises.');
    }
  }

  Future<void> addExercise(Exercise detail) async {
    await addExercises([detail]);
  }


  Future<void> removeExercise(int index) async {
    _resetInactivityTimer();
    if (state.session == null || index < 0 || index >= state.exercises.length) {
      return;
    }

    final se = state.exercises[index];
    final seId = se.id;

    try {
      // Remove from DB
      if (seId != null) {
        await ref.read(sessionsDaoProvider).deleteExercise(seId);
      }

      // Update State
      final updatedExercises = List<SessionExercise>.from(state.exercises)
        ..removeAt(index);
      final updatedSets = Map<int, List<SetEntry>>.from(state.sets)..remove(seId);

      // Re-index remaining exercises
      for (int i = 0; i < updatedExercises.length; i++) {
        updatedExercises[i] = updatedExercises[i].copyWith(orderIndex: i);
      }

      int? nextRestIndex = state.restingExerciseIndex;
      if (nextRestIndex == index) {
        nextRestIndex = null;
        ref.read(workoutTimerProvider.notifier).skipRest();
      } else if (nextRestIndex != null && nextRestIndex > index) {
        nextRestIndex--;
      }

      // LOCK CLEANUP: Remove stale lock entry for the deleted exercise.
      // Prevents accidental lock bleed if SQLite reuses the same integer ID
      // for a future inserted exercise.
      final updatedLocks = Set<int>.from(state.lockedExerciseIds);
      if (seId != null) updatedLocks.remove(seId);

      state = state.copyWith(
        exercises: updatedExercises,
        sets: updatedSets,
        restingExerciseIndex: nextRestIndex,
        lockedExerciseIds: updatedLocks,
      );

      GritHaptics.mediumImpact();
      _updateNotification();
    } catch (e) {
      debugPrint('GRIT ERROR: Failed to remove exercise: $e');
      state = state.copyWith(error: 'Failed to remove exercise.');
    }
  }

  Future<void> reorderExercises(int oldIndex, int newIndex) async {
    _resetInactivityTimer();
    if (state.session == null) return;
    if (oldIndex < 0 || oldIndex >= state.exercises.length) return;
    if (newIndex < 0 || newIndex > state.exercises.length) return;

    final exercises = List<SessionExercise>.from(state.exercises);
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final item = exercises.removeAt(oldIndex);
    exercises.insert(newIndex, item);

    // Update order indices
    final updatedExercises = <SessionExercise>[];
    final updates = <Map<String, int>>[];
    for (int i = 0; i < exercises.length; i++) {
      final updated = exercises[i].copyWith(orderIndex: i);
      updatedExercises.add(updated);
      if (updated.id != null && updated.id! > 0) {
        updates.add({'id': updated.id!, 'order_index': i});
      }
    }

    // Safety: If we're resting, we must clear or reset the index to avoid ghosting
    int? nextRestIndex = state.restingExerciseIndex;
    if (nextRestIndex != null) {
      // For simplicity and industrial-grade stability, we clear the rest timer if reordered mid-rest.
      nextRestIndex = null;
      ref.read(workoutTimerProvider.notifier).skipRest();
    }

    state = state.copyWith(
      exercises: updatedExercises,
      restingExerciseIndex: nextRestIndex,
    );

    try {
      // Persist to DB transactionally
      if (updates.isNotEmpty) {
        await ref.read(sessionsDaoProvider).updateExerciseOrderBulk(updates);
      }
    } catch (e) {
      debugPrint('GRIT ERROR: Failed to reorder exercises: $e');
      state = state.copyWith(error: 'Failed to save new order.');
    }
  }

  Future<void> swapExercise(int exerciseIndex, Exercise newDetail) async {
    _resetInactivityTimer();
    if (exerciseIndex < 0 ||
        exerciseIndex >= state.exercises.length ||
        state.session == null) {
      return;
    }

    final se = state.exercises[exerciseIndex];
    if (se.id == null || se.id! < 0) return; // Can't swap in preview

    final updatedSE = se.copyWith(
      exerciseId: newDetail.id!,
      exercise: newDetail,
    );

    try {
      // Persist to DB
      final sDao = ref.read(sessionsDaoProvider);
      final setDao = ref.read(setsDaoProvider);
      
      await sDao.updateExerciseType(se.id!, newDetail.id!);

      // Update state
      final updatedExercises = List<SessionExercise>.from(state.exercises);
      updatedExercises[exerciseIndex] = updatedSE;

      final updatedDetails = Map<int, Exercise>.from(state.exerciseDetails);
      updatedDetails[newDetail.id!] = newDetail;

      // Clear uncompleted sets so new ghost placeholders show up
      final updatedSetsMap = Map<int, List<SetEntry>>.from(state.sets);
      final currentSets = updatedSetsMap[se.id!] ?? [];
      final newSets = <SetEntry>[];
      
      for (final s in currentSets) {
        if (!s.isCompleted) {
          final clearedSet = s.copyWith(weightKg: 0.0, reps: null, durationSeconds: null, setType: SetEntryType.normal);
          newSets.add(clearedSet);
          await setDao.update(clearedSet); // Persist cleared state
        } else {
          newSets.add(s); // Keep completed sets as they might be legitimate history for the swapped exercise
        }
      }
      
      if (newSets.isEmpty) {
        // If all were somehow deleted, add one blank set
        final newSet = SetEntry(
          sessionExerciseId: se.id!,
          setNumber: 1,
          weightKg: 0.0,
          reps: null,
          loggedAt: DateTime.now().toIso8601String(),
        );
        final setId = await setDao.insert(newSet);
        newSets.add(newSet.copyWith(id: setId));
      }
      
      updatedSetsMap[se.id!] = newSets;

      final session = state.session;
      if (session == null) return;

      final benchmarks = await ref
          .read(setsDaoProvider)
          .getBestBenchmarksBefore(newDetail.id!, session.startedAt);

      final updatedBestWeights = Map<int, double>.from(state.bestWeights);
      updatedBestWeights[newDetail.id!] = benchmarks.weight;

      final updatedBestE1RMs = Map<int, double>.from(state.bestE1RMs);
      updatedBestE1RMs[newDetail.id!] = benchmarks.e1rm;

      final updatedBestSetVolumes = Map<int, double>.from(state.bestSetVolumes);
      updatedBestSetVolumes[newDetail.id!] = benchmarks.volume;

      final pSets = await ref
          .read(setsDaoProvider)
          .getSetsFromLastCompletedSession(newDetail.id!);

      final updatedPreviousSets = Map<int, List<SetEntry>>.from(state.previousSets);
      updatedPreviousSets[newDetail.id!] = pSets;

      state = state.copyWith(
        exercises: updatedExercises,
        exerciseDetails: updatedDetails,
        sets: updatedSetsMap,
        bestWeights: updatedBestWeights,
        bestE1RMs: updatedBestE1RMs,
        bestSetVolumes: updatedBestSetVolumes,
        previousSets: updatedPreviousSets,
      );

      _updateNotification();
    } catch (e) {
      debugPrint('GRIT ERROR: Failed to swap exercise: $e');
      state = state.copyWith(error: 'Failed to swap exercise.');
    }
  }

  void toggleExerciseLock(int sessionExerciseId) {
    final updatedLocks = Set<int>.from(state.lockedExerciseIds);
    if (updatedLocks.contains(sessionExerciseId)) {
      updatedLocks.remove(sessionExerciseId);
    } else {
      updatedLocks.add(sessionExerciseId);
    }
    state = state.copyWith(lockedExerciseIds: updatedLocks);
    GritHaptics.selectionTick();
  }

  void addRestTime(int seconds) {
    ref.read(workoutTimerProvider.notifier).addRestTime(seconds);
  }

  void toggleAutoRest() {
    state = state.copyWith(autoRestEnabled: !state.autoRestEnabled);
  }

  void setAutoRest(bool enabled) {
    state = state.copyWith(autoRestEnabled: enabled);
  }

  Future<void> cycleSetType(int exerciseIndex, int setIndex) async {
    _resetInactivityTimer();
    if (exerciseIndex >= state.exercises.length) return;
    final se = state.exercises[exerciseIndex];
    final currentSets = state.sets[se.id!] ?? [];
    if (setIndex >= currentSets.length) return;

    final s = currentSets[setIndex];
    SetEntryType nextType;
    switch (s.setType) {
      case SetEntryType.normal:
        nextType = SetEntryType.warmup;
        break;
      case SetEntryType.warmup:
        nextType = SetEntryType.dropSet;
        break;
      case SetEntryType.dropSet:
        nextType = SetEntryType.failure;
        break;
      case SetEntryType.failure:
        nextType = SetEntryType.normal;
        break;
    }

    final updated = s.copyWith(
      setType: nextType,
      // Strip PR status when cycling to warmup
      isPr: nextType == SetEntryType.warmup ? false : s.isPr,
    );
    await ref.read(setsDaoProvider).update(updated);

    final updatedSets = Map<int, List<SetEntry>>.from(state.sets);
    updatedSets[se.id!] = currentSets.asMap().entries.map((e) {
      return e.key == setIndex ? updated : e.value;
    }).toList();

    state = state.copyWith(sets: updatedSets);
    GritHaptics.selectionTick();
    _updateNotification();
  }

  Future<void> changeSetType(int exerciseIndex, int setIndex, SetEntryType newType) async {
    _resetInactivityTimer();
    if (exerciseIndex >= state.exercises.length) return;
    final se = state.exercises[exerciseIndex];
    final currentSets = state.sets[se.id!] ?? [];
    if (setIndex >= currentSets.length) return;

    final s = currentSets[setIndex];
    if (s.setType == newType) return;

    final updated = s.copyWith(
      setType: newType,
      isPr: newType == SetEntryType.warmup ? false : s.isPr,
    );
    await ref.read(setsDaoProvider).update(updated);

    final updatedSets = Map<int, List<SetEntry>>.from(state.sets);
    updatedSets[se.id!] = currentSets.asMap().entries.map((e) {
      return e.key == setIndex ? updated : e.value;
    }).toList();

    state = state.copyWith(sets: updatedSets);
    GritHaptics.selectionTick();
    _updateNotification();
  }

  Future<void> updateExerciseRestTime(int index, int seconds) async {
    if (index < 0 || index >= state.exercises.length) return;
    final se = state.exercises[index];
    final updatedSE = se.copyWith(targetRest: seconds);

    // Update DB (session_exercises only — NOT the source routine)
    await ref.read(sessionsDaoProvider).updateExerciseRestTime(se.id!, seconds);

    // Update State
    final updatedExercises = List<SessionExercise>.from(state.exercises);
    updatedExercises[index] = updatedSE;
    state = state.copyWith(
      exercises: updatedExercises,
      sessionRestOverride: seconds, // Set as session-wide default
    );

    // NOTE: _syncWithRoutine() intentionally removed here.
    // Rest time changes during an active session are session-scoped only.
    // The source routine must not be mutated mid-workout.

    _updateNotification();
  }

  void setSessionRestOverride(int seconds) {
    state = state.copyWith(sessionRestOverride: seconds);
    _updateNotification();
  }

  void adjustSessionRestOverride(int delta) {
    ref.read(workoutTimerProvider.notifier).addRestTime(delta);

    // Calculate new total duration from timer state after adjustment
    final timerState = ref.read(workoutTimerProvider);
    if (timerState.restStartTime != null && timerState.restEndTime != null) {
      final totalDuration = timerState.restEndTime!
          .difference(timerState.restStartTime!)
          .inSeconds;
      // ANTI-ZERO: Ensure the override is at least 1 second to avoid UI stuck at 00:00
      state = state.copyWith(
          sessionRestOverride: totalDuration > 0 ? totalDuration : 1);
    }
  }

  void startManualRest(int? exerciseIndex) {
    state = state.copyWith(restingExerciseIndex: exerciseIndex);
    final profile = ref.read(profileProvider);
    final details = WorkoutSessionManager.calculateNextSetRestDetails(
      exerciseIndex: exerciseIndex,
      exercises: state.exercises,
      sets: state.sets,
      exerciseDetails: state.exerciseDetails,
      sessionRestOverride: state.sessionRestOverride,
      profile: profile,
    );

    ref.read(workoutTimerProvider.notifier).startRestTimer(
          details.restSeconds,
          exerciseName: details.exerciseName,
          nextSetInfo: details.nextSetInfo,
          nextWeightRepsInfo: details.nextWeightRepsInfo,
        );
  }

  void skipRest() {
    ref.read(workoutTimerProvider.notifier).skipRest();
  }

  void updateSetField(int exerciseIndex, int setIndex,
      {double? weight, int? reps, bool isLb = false}) {
    if (exerciseIndex < 0 || exerciseIndex >= state.exercises.length) return;
    final se = state.exercises[exerciseIndex];
    final currentSets = state.sets[se.id!] ?? [];
    if (setIndex < 0 || setIndex >= currentSets.length) return;

    final s = currentSets[setIndex];

    // Convert to KG if input is in LB
    double? finalWeightKg;
    if (weight != null) {
      finalWeightKg = isLb ? weight * 0.45359237 : weight;
      // Precision hardening: round to 2 decimals to avoid floating point artifacts
      // and ensure consistent formatting in the UI/DB.
      finalWeightKg = double.parse(finalWeightKg.toStringAsFixed(2));
      finalWeightKg = finalWeightKg.clamp(0, 999.5);
    }

    final updated = s.copyWith(
      weightKg: finalWeightKg ?? s.weightKg,
      reps: reps?.clamp(0, 100) ?? s.reps,
    );

    updateSet(updated);
  }

  Future<void> completeSet(int exerciseIndex, int setIndex) async {
    _resetInactivityTimer();
    if (exerciseIndex < 0 || exerciseIndex >= state.exercises.length) return;
    final se = state.exercises[exerciseIndex];
    final currentSets = state.sets[se.id!] ?? [];
    if (setIndex < 0 || setIndex >= currentSets.length) return;

    final set = currentSets[setIndex];
    final becomesCompleted = !set.isCompleted;

    bool isPr = false;
    if (becomesCompleted) {
      final bestWeight = state.bestWeights[se.exerciseId] ?? 0.0;
      final bestE1RM = state.bestE1RMs[se.exerciseId] ?? 0.0;
      final bestVolume = state.bestSetVolumes[se.exerciseId] ?? 0.0;
      final exType = state.exerciseDetails[se.exerciseId]?.type ?? 'weighted';
      final profile = ref.read(profileProvider);

      isPr = WorkoutUtils.isPersonalRecord(
        set.copyWith(isCompleted: becomesCompleted),
        bestWeightBefore: bestWeight,
        bestE1RMBefore: bestE1RM,
        bestSetVolumeBefore: bestVolume,
        exerciseType: exType,
        userBodyweight: profile.weightKg,
      );
    }

    final updatedSet = set.copyWith(
      isCompleted: becomesCompleted,
      isPr: isPr,
      loggedAt: DateTime.now().toIso8601String(),
    );

    if (becomesCompleted) {
      if (isPr) {
        GritHaptics.prAchieved();
      } else {
        GritHaptics.setComplete();
      }
    } else {
      GritHaptics.lightImpact();
    }

    final updatedSets = Map<int, List<SetEntry>>.from(state.sets);
    updatedSets[se.id!] = currentSets.asMap().entries.map((entry) {
      return entry.key == setIndex ? updatedSet : entry.value;
    }).toList();

    state = state.copyWith(sets: updatedSets);

    if (becomesCompleted && state.autoRestEnabled) {
      final profile = ref.read(profileProvider);
      final details = WorkoutSessionManager.calculateNextSetRestDetails(
        exerciseIndex: exerciseIndex,
        exercises: state.exercises,
        sets: state.sets,
        exerciseDetails: state.exerciseDetails,
        sessionRestOverride: state.sessionRestOverride,
        profile: profile,
      );

      state = state.copyWith(restingExerciseIndex: exerciseIndex);
      ref.read(workoutTimerProvider.notifier).startRestTimer(
            details.restSeconds,
            exerciseName: details.exerciseName,
            nextSetInfo: details.nextSetInfo,
            nextWeightRepsInfo: details.nextWeightRepsInfo,
          );
    }

    ref.read(setsDaoProvider).update(updatedSet).ignore();
    _updateNotification();

    // Ensure dashboard reflects completion/un-ticking immediately
    Future.microtask(() {
      ref.invalidate(dashboardWorkoutProvider);
      ref.invalidate(dashboardDataProvider);
    });
  }

  Future<int?> finishWorkout() async {
    _inactivityTimer?.cancel();
    if (state.session == null || state.isLoading || state.isProcessing) return null;

    try {
      state = state.copyWith(isLoading: true, isProcessing: true, clearError: true);
      debugPrint('GRIT: Finishing workout...');

      _flushPendingSets();
      await GritWakelock.disable();

      final session = state.session;
      if (session == null) return null;
      final id = session.id;
      final profile = ref.read(profileProvider);
      final exTypesMap = {
        for (final se in state.exercises)
          se.id!: state.exerciseDetails[se.exerciseId]?.type ?? 'weighted'
      };
      final volume = WorkoutUtils.calculateTotalVolume(
          state.sets, exTypesMap, profile.weightKg);

      final cumulativeRest =
          ref.read(workoutTimerProvider).cumulativeRestSeconds;

      // TIME-ZONE HARDENING: Use UTC for start/end comparison to avoid local drift bugs
      final startedAtUtc = DateTime.parse(session.startedAt).toUtc();
      final nowUtc = DateTime.now().toUtc();
      final duration =
          nowUtc.difference(startedAtUtc).inSeconds.clamp(0, 86400);

      final finished = session.copyWith(
        endedAt: nowUtc.toIso8601String(),
        totalVolumeKg: volume,
        workoutDurationSeconds: duration,
        restDurationSeconds: cumulativeRest,
      );

      await ref.read(sessionsDaoProvider).update(finished);

      state = const ActiveWorkoutState();
      ref.read(workoutTimerProvider.notifier).reset();

      // Update notification to FINISHED state (persistent summary)
      NotificationService()
          .updateWorkoutNotification(
            sessionName: finished.name,
            isFinished: true,
            sessionId: finished.id,
          )
          .ignore();

      // Force invalidation of analysis and dashboard metrics to ensure fresh data
      Future.microtask(() {
        ref.invalidate(dashboardDataProvider);
        ref.invalidate(dashboardWorkoutProvider);
        ref.invalidate(muscleGroupSummariesProvider);
        ref.invalidate(allFinishedSessionsProvider);
        ref.invalidate(streakProvider);
        ref.invalidate(lastSessionProvider);
      });

      return id;
    } catch (e, stack) {
      debugPrint('GRIT ERROR: Failed to finish workout: $e');
      debugPrint('GRIT ERROR: Stack: $stack');
      state = state.copyWith(error: e.toString());
      return null;
    } finally {
      state = state.copyWith(isLoading: false, isProcessing: false);
    }
  }

  Future<void> discardWorkout() async {
    _inactivityTimer?.cancel();
    final sDao = ref.read(sessionsDaoProvider);

    // Stop and clear all timers first to stop notification updates
    ref.read(workoutTimerProvider.notifier).reset();
    ref
        .read(workoutTimerProvider.notifier)
        .stopElapsedTimer(); // Force clear SharedPreferences

    final session = state.session;
    if (session != null) {
      final id = session.id;
      if (id != null) {
        await sDao.delete(id);
      }
    }

    // Ensure database is truly clean of active markers
    await sDao.closeAllActiveSessions();

    state = const ActiveWorkoutState();

    // Final notification cleanup
    NotificationService().cancelWorkoutNotification().ignore();
    await GritWakelock.disable();

    Future.microtask(() {
      ref.invalidate(dashboardDataProvider);
      ref.invalidate(dashboardWorkoutProvider);
      ref.invalidate(muscleGroupSummariesProvider);
      ref.invalidate(streakProvider);
    });
  }

  Future<void> replaceActiveWorkout(int newRoutineId,
      {required bool shouldSave}) async {
    state = state.copyWith(isLoading: true, clearPreview: true);
    if (shouldSave) {
      await finishWorkout();
    } else {
      await discardWorkout();
    }
    // No delayed hack needed if we await finishWorkout which clears state correctly
    await startWorkout(newRoutineId);
    state = state.copyWith(isLoading: false);
  }

  Future<void> _updateNotification() async {
    final session = state.session;
    if (session == null) return;

    final profile = ref.read(profileProvider);
    final data = WorkoutNotificationManager.calculateNotificationData(
      exercises: state.exercises,
      sets: state.sets,
      exerciseDetails: state.exerciseDetails,
      restingExerciseIndex: state.restingExerciseIndex,
      profile: profile,
    );

    if (data != null) {
      ref.read(workoutTimerProvider.notifier).updateWorkoutInfo(
            sessionName: session.name,
            exerciseName: data.exerciseName,
            setInfo: data.setInfo,
            weightInfo: data.weightInfo,
            repsInfo: data.repsInfo,
            startedAt: DateTime.tryParse(session.startedAt),
            currentExerciseIndex: data.currentIndex + 1,
            totalExercises: state.exercises.length,
          );
    }
  }
}

final activeWorkoutProvider =
    NotifierProvider<ActiveWorkoutNotifier, ActiveWorkoutState>(
  ActiveWorkoutNotifier.new,
);
