import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'dart:ui' as ui;
import '../../core/theme/grit_theme.dart';
import '../../core/utils/haptics.dart';
import '../../providers/workout_provider.dart';
import '../../data/models/exercise.dart';
import 'components/rest_timer_panel.dart';
import 'components/exercise_block.dart';
import 'components/finish_workout_sheet.dart';
import 'components/header_timer_segment.dart';
import 'components/slide_to_discard.dart';
import '../../core/constants/hero_tags.dart';
import '../../shared/widgets/grit_skeleton.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../app/routes.dart';

class ActiveWorkoutScreen extends ConsumerStatefulWidget {
  const ActiveWorkoutScreen({super.key});

  @override
  ConsumerState<ActiveWorkoutScreen> createState() =>
      _ActiveWorkoutScreenState();
}

class _ActiveWorkoutScreenState extends ConsumerState<ActiveWorkoutScreen> {
  @override
  Widget build(BuildContext context) {
    ref.listen<ActiveWorkoutState>(activeWorkoutProvider, (previous, next) {
      if (next.error != null && next.error != previous?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next.error!),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    });

    final exercises =
        ref.watch(activeWorkoutProvider.select((s) => s.exercises));
    final exercisesCount = exercises.length;
    final hasActiveSession =
        ref.watch(activeWorkoutProvider.select((s) => s.hasActiveSession));
    final isLoading =
        ref.watch(activeWorkoutProvider.select((s) => s.isLoading));
    final isPreview =
        ref.watch(activeWorkoutProvider.select((s) => s.isPreview));
    final sessionName =
        ref.watch(activeWorkoutProvider.select((s) => s.session?.name));
    final previewRoutineName =
        ref.watch(activeWorkoutProvider.select((s) => s.previewRoutine?.name));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        GritHaptics.buttonTap();
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(GritRoutes.workout);
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).grit.background,
        appBar: (hasActiveSession && sessionName != null)
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: AppBar(
                  backgroundColor: Theme.of(context).grit.surface,
                  elevation: 0,
                  centerTitle: false,
                  titleSpacing: 0,
                  automaticallyImplyLeading: false,
                  leading: IconButton(
                    icon: Icon(PhosphorIcons.arrowLeft(),
                        size: 20, color: Theme.of(context).grit.textSecondary),
                    onPressed: () {
                      GritHaptics.buttonTap();
                      if (context.canPop()) {
                        context.pop();
                      } else {
                        context.go(GritRoutes.workout);
                      }
                    },
                  ),
                  title: Hero(
                    tag: HeroTags.activeWorkoutName,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Text(sessionName.toUpperCase(),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: GritTextStyles.metric(
                            22,
                            color: Theme.of(context).grit.textPrimary,
                          )),
                    ),
                  ),
                  actions: const [
                    HeaderTimerSegment(),
                  ],
                  bottom: PreferredSize(
                    preferredSize: const Size.fromHeight(1),
                    child: Divider(
                        height: 1, thickness: 1, color: Theme.of(context).grit.border),
                  ),
                ),
              )
            : (isPreview && previewRoutineName != null)
                ? PreferredSize(
                    preferredSize: const Size.fromHeight(56),
                    child: AppBar(
                      backgroundColor: Theme.of(context).grit.surface,
                      elevation: 0,
                      centerTitle: false,
                      titleSpacing: 0,
                      leading: IconButton(
                        icon: Icon(PhosphorIcons.arrowLeft(),
                            size: 20, color: Theme.of(context).grit.textSecondary),
                        onPressed: () {
                          GritHaptics.buttonTap();
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go(GritRoutes.workout);
                          }
                        },
                      ),
                      title: Text(previewRoutineName.toUpperCase(),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: GritTextStyles.metric(
                            22,
                            weight: FontWeight.w900,
                            color: Theme.of(context).grit.textPrimary,
                          )),
                      bottom: PreferredSize(
                        preferredSize: const Size.fromHeight(1),
                        child: Divider(
                            height: 1, thickness: 1, color: Theme.of(context).grit.border),
                      ),
                    ),
                  )
                : null,
        body: SafeArea(
          child: Column(
            children: [
              if (hasActiveSession) ...[
                const RestTimerPanel(),
              ],
              Expanded(
                child: Container(
                  color: Theme.of(context).grit.background,
                  child: isLoading
                      ? ListView.builder(
                          padding: const EdgeInsets.symmetric(
                              horizontal: GritSpacing.horizontalMargin,
                              vertical: 20),
                          itemCount: 3,
                          itemBuilder: (c, i) => Container(
                            margin: const EdgeInsets.only(bottom: 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                GritSkeleton(
                                    height: 140, width: double.infinity),
                                const SizedBox(height: 12),
                                Row(
                                  children: List.generate(
                                      4,
                                      (index) => Expanded(
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 4),
                                              child: GritSkeleton(height: 32),
                                            ),
                                          )),
                                ),
                              ],
                            ),
                          ),
                        )
                      : ReorderableListView.builder(
                          padding: EdgeInsets.zero,
                          onReorder: (oldIndex, newIndex) {
                            if (!isPreview) {
                              if (oldIndex < exercisesCount &&
                                  newIndex <= exercisesCount) {
                                ref
                                    .read(activeWorkoutProvider.notifier)
                                    .reorderExercises(oldIndex, newIndex);
                              }
                            }
                          },
                          proxyDecorator: (child, index, animation) {
                            return AnimatedBuilder(
                              animation: animation,
                              builder: (context, child) {
                                final animValue =
                                    Curves.easeInOut.transform(animation.value);
                                final elevation =
                                    ui.lerpDouble(0, 8, animValue)!;
                                return Material(
                                  elevation: elevation,
                                  color: Theme.of(context).grit.surface2,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                          color: Theme.of(context).grit.accent, width: 1),
                                    ),
                                    child: child,
                                  ),
                                );
                              },
                              child: child,
                            );
                          },
                          itemCount: exercisesCount + 1,
                          itemBuilder: (ctx, i) {
                            if (i == exercisesCount) {
                              return Container(
                                key: const ValueKey('footer'),
                                child: hasActiveSession
                                    ? _buildBottomButtons(context)
                                    : Builder(
                                        builder: (context) => SizedBox(
                                            height: MediaQuery.of(context)
                                                    .padding
                                                    .bottom +
                                                100)),
                              );
                            }
                            if (i >= exercises.length) return const SizedBox.shrink();
                            final se = exercises[i];
                            if (isPreview) {
                              return ExerciseBlock(
                                  exerciseIndex: i, key: ValueKey(se.id ?? i));
                            }

                            return Slidable(
                              // KEY FIX: Use only se.id (stable DB id).
                              // Previously included se.exerciseId which changes
                              // on swap, causing full widget destruction and
                              // stale UI until the next frame rebuild.
                              key: ValueKey('slidable_${se.id ?? i}'),
                              endActionPane: ActionPane(
                                motion: const StretchMotion(),
                                extentRatio: 0.3,
                                children: [
                                  CustomSlidableAction(
                                    onPressed: (_) =>
                                        _showSwapExerciseFlow(context, i),
                                    backgroundColor: Theme.of(context).grit.surface2,
                                    foregroundColor: Theme.of(context).grit.textSecondary,
                                    child: Icon(PhosphorIcons.arrowsLeftRight(),
                                        size: 22),
                                  ),
                                  CustomSlidableAction(
                                    onPressed: (_) =>
                                        _showRemoveExerciseDialog(context, i),
                                    backgroundColor: Theme.of(context).grit.accent
                                        .withValues(alpha: 0.8),
                                    foregroundColor: Colors.white,
                                    child: Icon(PhosphorIcons.trash(),
                                        size: 22, color: Colors.white),
                                  ),
                                ],
                              ),
                              child: RepaintBoundary(
                                // KEY FIX: Stable key so Flutter correctly
                                // tracks the ExerciseBlock across list mutations
                                // (add/remove/reorder). Without this key, Flutter
                                // reuses widget objects at wrong indices.
                                child: ExerciseBlock(
                                  key: ValueKey('eb_${se.id ?? i}'),
                                  exerciseIndex: i,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
              if (isPreview) ...[
                Consumer(builder: (context, ref, child) {
                  final rId = ref.watch(activeWorkoutProvider
                      .select((s) => s.previewRoutine?.id));
                  return rId != null
                      ? _buildPreviewStartButton(context, ref, rId)
                      : const SizedBox.shrink();
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewStartButton(
      BuildContext context, WidgetRef ref, int routineId) {
    return Padding(
      padding: const EdgeInsets.all(GritSpacing.horizontalMargin),
      child: GestureDetector(
        onTap: () async {
          await ref
              .read(activeWorkoutProvider.notifier)
              .startWorkout(routineId);
          await GritHaptics.workoutStart();
        },
        child: Container(
          height: GritSpacing.btnPrimary,
          decoration: BoxDecoration(
            color: Theme.of(context).grit.accent,
            borderRadius: BorderRadius.zero,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('START ROUTINE',
                  style: GritTextStyles.labelCaps().copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomButtons(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          GritSpacing.horizontalMargin,
          GritSpacing.sectionSpacing,
          GritSpacing.horizontalMargin,
          48), // Adjusted for safe area balance
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: () async {
              final exercises = await context
                  .push<List<Exercise>>(GritRoutes.exerciseLibrarySelect);
              if (exercises != null &&
                  exercises.isNotEmpty &&
                  context.mounted) {
                await ref
                    .read(activeWorkoutProvider.notifier)
                    .addExercises(exercises);
              }
            },
            child: Container(
              height: GritSpacing.btnPrimary,
              decoration: BoxDecoration(
                color: Colors.transparent,
                border:
                    Border.all(color: Theme.of(context).grit.border, width: 1.5),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(PhosphorIcons.plus(),
                      color: Theme.of(context).grit.textSecondary, size: 18),
                  const SizedBox(width: 10),
                  Text('ADD EXERCISES',
                      style: GritTextStyles.labelCaps()
                           .copyWith(color: Theme.of(context).grit.textSecondary)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => _showFinishSheet(context),
            child: Container(
              height: GritSpacing.btnPrimary,
              decoration: BoxDecoration(
                color: Theme.of(context).grit.accent,
                borderRadius: BorderRadius.zero,
              ),
              alignment: Alignment.center,
              child: Text('FINISH WORKOUT',
                  style: GritTextStyles.labelCaps().copyWith(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                    color: Colors.white,
                    letterSpacing: 2.5,
                  )),
            ),
          ),
          const SizedBox(height: 12),
          SlideToDiscard(
            onDiscard: () => _showDiscardDialog(context),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }

  Future<void> _showDiscardDialog(BuildContext context) async {
    final reallyDiscard = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(context).grit.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: Text('DISCARD WORKOUT?', style: GritTextStyles.metric(22, color: Theme.of(context).grit.textPrimary)),
        content: Text('ALL PROGRESS FOR THIS SESSION WILL BE LOST.',
            style: GritTextStyles.label(13, color: Theme.of(context).grit.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text('CANCEL',
                  style: GritTextStyles.labelCaps()
                      .copyWith(color: Theme.of(context).grit.textPrimary))),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text('DISCARD',
                  style: GritTextStyles.labelCaps()
                      .copyWith(color: Theme.of(context).grit.accent))),
        ],
      ),
    );

    if (reallyDiscard == true && context.mounted) {
      context.go(GritRoutes.workout);
      ref.read(activeWorkoutProvider.notifier).discardWorkout();
      GritHaptics.mediumImpact();
    }
  }

  void _showRemoveExerciseDialog(BuildContext context, int index) async {
    final state = ref.read(activeWorkoutProvider);
    final se = state.exercises[index];
    final name = state.exerciseDetails[se.exerciseId]?.name ?? 'Exercise';

    final reallyRemove = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(context).grit.surface,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        title: Text('REMOVE EXERCISE?', style: GritTextStyles.metric(22, color: Theme.of(context).grit.textPrimary)),
        content: Text('REALLY REMOVE ${name.toUpperCase()} FROM THIS SESSION?',
            style: GritTextStyles.label(13, color: Theme.of(context).grit.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text('CANCEL',
                  style: GritTextStyles.labelCaps()
                      .copyWith(color: Theme.of(context).grit.textPrimary))),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text('REMOVE',
                  style: GritTextStyles.labelCaps()
                      .copyWith(color: Theme.of(context).grit.accent))),
        ],
      ),
    );

    if (reallyRemove == true && context.mounted) {
      await ref.read(activeWorkoutProvider.notifier).removeExercise(index);
      await GritHaptics.mediumImpact();
    }
  }

  void _showSwapExerciseFlow(BuildContext context, int index) async {
    final exercises =
        await context.push<List<Exercise>>(GritRoutes.exerciseLibrarySwap);

    if (exercises != null && exercises.isNotEmpty && context.mounted) {
      final newExercise = exercises.first;
      await ref
          .read(activeWorkoutProvider.notifier)
          .swapExercise(index, newExercise);
      await GritHaptics.selectionTick();
    }
  }

  void _showFinishSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).grit.background,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      builder: (ctx) => FinishWorkoutSheet(
        onSave: () async {
          Navigator.pop(ctx);
          final id =
              await ref.read(activeWorkoutProvider.notifier).finishWorkout();
          if (id != null) {
            await GritHaptics.workoutComplete();
          }
          if (context.mounted) {
            if (id != null) {
              context.go(GritRoutes.workoutSummary(id));
            }
          }
        },
        onDiscard: () async {
          Navigator.pop(ctx);
          _showDiscardDialog(context);
        },
      ),
    );
  }
}
