import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/book_transcriber.dart';
import '../services/player_settings.dart';
import '../services/transcription_service.dart';
import 'absorbing_shared.dart';
import 'overlay_toast.dart';

/// Start, watch and stop transcribing a whole book.
void showBookTranscribeSheet(
  BuildContext context, {
  required String itemId,
  required String title,
  Color? accent,
}) {
  showModalBottomSheet(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BookTranscribeBody(
      itemId: itemId,
      title: title,
      accent: accent ?? Theme.of(context).colorScheme.primary,
    ),
  );
}

class _BookTranscribeBody extends StatefulWidget {
  final String itemId;
  final String title;
  final Color accent;
  const _BookTranscribeBody({
    required this.itemId,
    required this.title,
    required this.accent,
  });

  @override
  State<_BookTranscribeBody> createState() => _BookTranscribeBodyState();
}

class _BookTranscribeBodyState extends State<_BookTranscribeBody> {
  final _job = BookTranscriber.instance;
  double? _coverage;
  String _engine = 'whisper';

  @override
  void initState() {
    super.initState();
    _job.addListener(_changed);
    _job.coverage(widget.itemId).then((c) {
      if (mounted) setState(() => _coverage = c);
    });
    PlayerSettings.getTranscriptionEngine().then((e) {
      if (mounted) setState(() => _engine = e);
    });
  }

  @override
  void dispose() {
    _job.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final l = AppLocalizations.of(context)!;
    if (!await TranscriptionService.instance
        .canTranscribeNow(feature: TranscriptionFeature.bookmarks)) {
      if (mounted) showOverlayToast(context, l.transcriptionNoModelDownloaded);
      return;
    }
    final ok = await _job.start(widget.itemId, widget.title);
    if (!ok && mounted) {
      showOverlayToast(
          context,
          _job.running
              ? l.bookTranscribeOtherRunning(_job.title ?? '')
              : l.transcriptionNotDownloadedBook);
    }
  }

  String _dur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final mine = _job.itemId == widget.itemId;
    final running = _job.isRunningFor(widget.itemId);
    final otherRunning = _job.running && !mine;
    final fraction = mine && (_job.running || _job.coveredSeconds > 0)
        ? _job.fraction
        : (_coverage ?? 0);
    final stop = _job.stopReasonFor(widget.itemId);
    final speed = running ? _job.speed : null;
    final left = running ? _job.remaining : null;

    String? status;
    if (running) {
      status = speed == null
          ? l.bookTranscribeWarmingUp
          : l.bookTranscribeSpeed(speed.toStringAsFixed(1),
              left == null ? '-' : _dur(left));
    } else if (_job.finishedFor(widget.itemId) || fraction >= 0.999) {
      status = l.bookTranscribeDone;
    } else if (stop == BookTranscribeStop.battery) {
      status = l.bookTranscribeBatteryNotif;
    } else if (stop == BookTranscribeStop.failed) {
      status = l.bookTranscribeFailedNotif;
    } else if (otherRunning) {
      status = l.bookTranscribeOtherRunning(_job.title ?? '');
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).bottomSheetTheme.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: widget.accent.withValues(alpha: 0.2))),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(l.bookTranscribeTitle,
              textAlign: TextAlign.center,
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(widget.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 10,
              color: widget.accent,
              backgroundColor: widget.accent.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Text('${(fraction * 100).toStringAsFixed(1)}%',
                style: tt.titleSmall?.copyWith(
                    color: widget.accent, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (mine && _job.totalSeconds > 0)
              Text('${fmtTime(_job.coveredSeconds)} / ${fmtTime(_job.totalSeconds)}',
                  style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ]),
          if (status != null) ...[
            const SizedBox(height: 8),
            Text(status, style: tt.bodyMedium),
          ],
          const SizedBox(height: 12),
          Text(
            l.bookTranscribeHint(_engine == 'parakeet'
                ? l.transcriptionEngineParakeet
                : l.transcriptionEngineWhisper),
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 16),
          if (running)
            OutlinedButton.icon(
              onPressed: _job.stop,
              icon: const Icon(Icons.stop_rounded),
              label: Text(l.bookTranscribeStop),
            )
          else
            FilledButton.icon(
              onPressed: otherRunning || fraction >= 0.999 ? null : _start,
              style: FilledButton.styleFrom(backgroundColor: widget.accent),
              icon: const Icon(Icons.record_voice_over_rounded),
              label: Text(fraction > 0.001
                  ? l.bookTranscribeContinue
                  : l.bookTranscribeStart),
            ),
        ],
      ),
    );
  }
}
