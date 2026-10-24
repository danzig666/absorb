import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_player_service.dart';
import '../services/playback_history_service.dart';
import '../services/sleep_spot_finder.dart';
import '../services/transcript_line_store.dart';
import '../services/transcription_service.dart';
import 'absorbing_shared.dart';
import 'overlay_toast.dart';

/// "Where did I fall asleep?" - finds the spot to go back to after dozing
/// off, three ways: the last thing only an awake listener does, a clock time
/// the listener remembers, and the transcript of what was playing then.
void showSleepSpotSheet(
  BuildContext context, {
  required String itemId,
  String? episodeId,
  Color? accent,
  AudioPlayerService? player,
}) {
  final resolvedPlayer = player ?? AudioPlayerService();
  final isActive = resolvedPlayer.currentItemId == itemId &&
      (episodeId == null || resolvedPlayer.currentEpisodeId == episodeId);
  final theme = Theme.of(context);
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.05,
      snap: true,
      maxChildSize: 0.95,
      builder: (_, scrollController) => _SleepSpotBody(
        itemId: itemId,
        episodeId: episodeId,
        accent: accent ?? theme.colorScheme.primary,
        player: resolvedPlayer,
        isActive: isActive,
        parentCtx: context,
        scrollController: scrollController,
      ),
    ),
  );
}

class _SleepSpotBody extends StatefulWidget {
  final String itemId;
  final String? episodeId;
  final Color accent;
  final AudioPlayerService player;
  final bool isActive;
  final BuildContext parentCtx;
  final ScrollController scrollController;

  const _SleepSpotBody({
    required this.itemId,
    this.episodeId,
    required this.accent,
    required this.player,
    required this.isActive,
    required this.parentCtx,
    required this.scrollController,
  });

  @override
  State<_SleepSpotBody> createState() => _SleepSpotBodyState();
}

class _SleepSpotBodyState extends State<_SleepSpotBody> {
  // How much text to show around the spot, and how much more Earlier and
  // Later add. Transcription goes in 30 second windows.
  static const _textBefore = 120.0;
  static const _textAfter = 480.0;
  static const _textStep = 180.0;
  static const _window = 30.0;

  // Sessions listed before "Show earlier".
  static const _sessionsShown = 4;

  SleepSpotFinder? _finder;
  List<ListeningSession> _sessions = const [];
  ListeningSession? _selected;
  bool _showAllSessions = false;
  SleepSpot? _clockSpot;
  TimeOfDay? _pickedTime;
  bool _pickedTimeMissing = false;
  double _speed = 1.0;
  bool _speedAdjusted = true;

  // The text section: the spot it is centred on and the stretch shown.
  SleepSpot? _textSpot;
  double _textFrom = 0;
  double _textTo = 0;
  List<TranscriptLine> _lines = const [];
  bool _transcribing = false;
  int _done = 0;
  int _total = 0;
  bool _disposed = false;

  String get _key =>
      widget.episodeId != null ? '${widget.itemId}-${widget.episodeId}' : widget.itemId;

  double get _displaySpeed => _speedAdjusted ? _speed : 1.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    final history = await PlaybackHistoryService().getHistory(widget.itemId);
    final saved = await PlayerSettings.getBookSpeed(widget.itemId);
    final speed = widget.isActive
        ? widget.player.speed
        : (saved ?? await PlayerSettings.getDefaultSpeed());
    final adjusted = await PlayerSettings.getSpeedAdjustedTime();
    final finder = SleepSpotFinder(
      history,
      speed: speed,
      livePosition: widget.isActive
          ? widget.player.position.inMilliseconds / 1000.0
          : null,
      livePlaying: widget.isActive && widget.player.isPlaying,
    );
    if (!mounted) return;
    setState(() {
      _finder = finder;
      _speed = speed;
      _speedAdjusted = adjusted;
      _sessions = finder.sessions();
      _selected = finder.likelySleepSession();
    });
    final start = _selected?.spot;
    if (start != null) await _showTextFor(start);
  }

  Future<void> _select(ListeningSession s) async {
    setState(() => _selected = s);
    await _showTextFor(s.spot);
  }

  String _clock(DateTime t) {
    final use24 = MediaQuery.of(context).alwaysUse24HourFormat;
    return MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: use24);
  }

  String _pos(double seconds) => fmtTime(seconds / _displaySpeed);

  void _jump(double seconds) {
    final l = AppLocalizations.of(context)!;
    if (!widget.isActive) {
      showOverlayToast(context, l.sleepSpotNeedsActive, icon: Icons.info_outline_rounded);
      return;
    }
    widget.player.seekTo(Duration(milliseconds: (seconds * 1000).round()));
    Navigator.pop(context);
    showOverlayToast(widget.parentCtx, l.jumpedToPosition(_pos(seconds)),
        icon: Icons.my_location_rounded);
  }

  Future<void> _pickTime() async {
    final initial = _pickedTime ??
        TimeOfDay.fromDateTime(_selected?.spot.at ?? DateTime.now());
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final spot = _finder?.spotAtClockTime(picked.hour, picked.minute);
    setState(() {
      _pickedTime = picked;
      _clockSpot = spot;
      _pickedTimeMissing = spot == null;
    });
    if (spot != null) await _showTextFor(spot);
  }

  Future<void> _showTextFor(SleepSpot spot) async {
    _textSpot = spot;
    _textFrom = (spot.positionSeconds - _textBefore).clamp(0.0, double.infinity);
    _textTo = spot.positionSeconds + _textAfter;
    await _refreshLines();
  }

  Future<void> _refreshLines() async {
    await TranscriptLineStore.instance.hydrate(_key);
    if (!mounted) return;
    setState(() {
      _lines = TranscriptLineStore.instance.between(_key, _textFrom, _textTo);
    });
  }

  Future<void> _extend({required bool earlier}) async {
    setState(() {
      if (earlier) {
        _textFrom = (_textFrom - _textStep).clamp(0.0, double.infinity);
      } else {
        _textTo += _textStep;
      }
    });
    await _refreshLines();
  }

  /// The 30 second windows in the shown stretch nothing has transcribed yet.
  List<double> _missingWindows() {
    final store = TranscriptLineStore.instance;
    final out = <double>[];
    for (var s = _textFrom; s < _textTo; s += _window) {
      if (store.coveredUntil(_key, s) < s + _window - 2) out.add(s);
    }
    return out;
  }

  Future<void> _transcribe() async {
    final l = AppLocalizations.of(context)!;
    final svc = TranscriptionService.instance;
    if (!await svc.canTranscribeNow(feature: TranscriptionFeature.bookmarks)) {
      if (mounted) showOverlayToast(context, l.transcriptionDisabledHint);
      return;
    }
    // Start next to the spot and work outwards, so the lines that matter
    // most show up first.
    final centre = _textSpot?.positionSeconds ?? _textFrom;
    final windows = _missingWindows()
      ..sort((a, b) => (a - centre).abs().compareTo((b - centre).abs()));
    if (windows.isEmpty) return;
    setState(() {
      _transcribing = true;
      _done = 0;
      _total = windows.length;
    });
    String? error;
    for (final start in windows) {
      if (_disposed) return;
      try {
        final words = await svc.transcribeWindowSegments(
          itemId: widget.itemId,
          startSeconds: start,
          windowSeconds: _window,
          feature: TranscriptionFeature.bookmarks,
        );
        await TranscriptLineStore.instance
            .addLines(_key, transcriptLinesFromWords(words, start));
      } on TranscriptionException catch (e) {
        if (e.kind == TranscriptionError.empty) {
          // Music or silence - nothing to show, carry on.
        } else {
          error = _errorText(l, e.kind);
          break;
        }
      } catch (_) {
        error = l.transcriptionFailedMsg;
        break;
      }
      if (_disposed) return;
      _done++;
      await _refreshLines();
    }
    if (!mounted) return;
    setState(() => _transcribing = false);
    if (error != null) showOverlayToast(context, error);
  }

  String _errorText(AppLocalizations l, TranscriptionError kind) {
    switch (kind) {
      case TranscriptionError.disabled:
        return l.transcriptionDisabledHint;
      case TranscriptionError.modelMissing:
        return l.transcriptionNoModelDownloaded;
      case TranscriptionError.notDownloaded:
        return l.transcriptionNotDownloadedBook;
      case TranscriptionError.noMetadata:
        return l.transcriptionNoMetadataMsg;
      case TranscriptionError.busy:
        return l.transcriptionBusyMsg;
      case TranscriptionError.empty:
        return l.transcriptionEmptyMsg;
      case TranscriptionError.extractFailed:
      case TranscriptionError.transcribeFailed:
        return l.transcriptionFailedMsg;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final finder = _finder;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).bottomSheetTheme.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: widget.accent.withValues(alpha: 0.2), width: 1)),
      ),
      child: finder == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    width: 40, height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.24),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(l.sleepSpotTitle,
                    textAlign: TextAlign.center,
                    style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(l.sleepSpotIntro,
                    textAlign: TextAlign.center,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 16),
                _sessionsCard(l, cs, tt),
                const SizedBox(height: 12),
                _clockCard(l, cs, tt),
                const SizedBox(height: 20),
                ..._textSection(l, cs, tt),
              ],
            ),
    );
  }

  Widget _card(ColorScheme cs, List<Widget> children) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: widget.accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: widget.accent.withValues(alpha: 0.15)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _cardTitle(IconData icon, String text, TextTheme tt) => Row(children: [
        Icon(icon, size: 18, color: widget.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
      ]);

  Widget _sessionsCard(AppLocalizations l, ColorScheme cs, TextTheme tt) {
    final shown = _showAllSessions
        ? _sessions
        : _sessions.take(_sessionsShown).toList();
    final selected = _selected;
    return _card(cs, [
      _cardTitle(Icons.history_rounded, l.sleepSpotSessionsTitle, tt),
      const SizedBox(height: 4),
      Text(_sessions.isEmpty ? l.sleepSpotNoAwake : l.sleepSpotSessionsHint,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      const SizedBox(height: 6),
      for (final s in shown) _sessionTile(l, cs, tt, s, identical(s, selected)),
      if (!_showAllSessions && _sessions.length > _sessionsShown)
        TextButton.icon(
          onPressed: () => setState(() => _showAllSessions = true),
          icon: const Icon(Icons.expand_more_rounded),
          label: Text(l.sleepSpotShowEarlier),
        ),
      if (selected != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: () => _jump(selected.spot.positionSeconds),
              icon: const Icon(Icons.my_location_rounded, size: 18),
              label: Text(l.sleepSpotJump),
              style: FilledButton.styleFrom(backgroundColor: widget.accent),
            ),
            OutlinedButton.icon(
              onPressed: () => _jump(selected.endPosition),
              icon: const Icon(Icons.stop_circle_outlined, size: 18),
              label: Text(l.sleepSpotJumpToStop),
            ),
          ]),
        ),
    ]);
  }

  Widget _sessionTile(AppLocalizations l, ColorScheme cs, TextTheme tt,
      ListeningSession s, bool selected) {
    final small = tt.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final awake = s.lastAwake;
    final IconData icon;
    final String ended;
    if (s.endEvent == null) {
      icon = Icons.play_arrow_rounded;
      ended = l.sleepSpotSessionOngoing;
    } else if (s.endedBySleepTimer) {
      icon = Icons.bedtime_rounded;
      ended = l.sleepSpotSessionTimer(_pos(s.endPosition));
    } else {
      icon = Icons.pause_rounded;
      ended = l.sleepSpotSessionPaused(_pos(s.endPosition));
    }
    final length = s.length.inSeconds / 1.0;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _select(s),
      child: Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? widget.accent.withValues(alpha: 0.14) : null,
          border: Border.all(
              color: selected
                  ? widget.accent.withValues(alpha: 0.6)
                  : cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(s.likelyAccidental ? Icons.touch_app_rounded : icon,
              size: 20,
              color: s.likelyAccidental ? cs.error : widget.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  '${dateLabel(s.start, l)} ${_clock(s.start)}–${_clock(s.end)} · ${fmtDur(length)}',
                  style: tt.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
              Text(
                  awake != null
                      ? l.sleepSpotSessionAwake(_clock(awake.at), _pos(awake.positionSeconds))
                      : l.sleepSpotSessionNoAwake(_pos(s.startPosition)),
                  style: small),
              Text(ended, style: small),
              if (s.likelyAccidental)
                Text(l.sleepSpotSessionAccidental,
                    style: tt.bodySmall?.copyWith(color: cs.error))
              else if (s.fromMediaButton)
                Text(l.sleepSpotSessionFromButton, style: small),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _clockCard(AppLocalizations l, ColorScheme cs, TextTheme tt) {
    final spot = _clockSpot;
    final picked = _pickedTime;
    return _card(cs, [
      _cardTitle(Icons.schedule_rounded, l.sleepSpotClockTitle, tt),
      const SizedBox(height: 8),
      if (spot != null)
        Text(l.sleepSpotAtTime(_clock(spot.at), _pos(spot.positionSeconds)),
            style: tt.bodyMedium)
      else if (_pickedTimeMissing && picked != null)
        Text(
            l.sleepSpotNoHistoryForTime(
                MaterialLocalizations.of(context).formatTimeOfDay(picked,
                    alwaysUse24HourFormat:
                        MediaQuery.of(context).alwaysUse24HourFormat)),
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _pickTime,
            icon: const Icon(Icons.access_time_rounded, size: 18),
            label: Text(l.sleepSpotPickTime),
          ),
          if (spot != null)
            FilledButton.icon(
              onPressed: () => _jump(spot.positionSeconds),
              icon: const Icon(Icons.my_location_rounded, size: 18),
              label: Text(l.sleepSpotJump),
              style: FilledButton.styleFrom(backgroundColor: widget.accent),
            ),
        ]),
      ),
    ]);
  }

  List<Widget> _textSection(AppLocalizations l, ColorScheme cs, TextTheme tt) {
    final spot = _textSpot;
    if (spot == null) return const [];
    if (widget.episodeId != null) {
      return [
        Text(l.sleepSpotNoPodcastText,
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ];
    }
    final finder = _finder!;
    final missing = _missingWindows();
    final out = <Widget>[
      _cardTitle(Icons.subtitles_rounded, l.sleepSpotTextTitle(_clock(spot.at)), tt),
      const SizedBox(height: 4),
      Text(l.sleepSpotTextHint,
          style: tt.bodySmall?.copyWith(
              color: cs.onSurfaceVariant, fontStyle: FontStyle.italic)),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _textFrom <= 0 ? null : () => _extend(earlier: true),
          icon: const Icon(Icons.expand_less_rounded),
          label: Text(l.sleepSpotEarlier),
        ),
      ),
    ];
    if (_lines.isEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(l.sleepSpotNoText,
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
      ));
    }
    for (final line in _lines) {
      final at = finder.timeAtPosition(line.start, near: spot.at);
      final isSpot = spot.positionSeconds >= line.start &&
          spot.positionSeconds <= line.end + 1;
      out.add(InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _jump(line.start),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: isSpot
              ? BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                )
              : null,
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 64,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(at != null ? _clock(at) : '',
                    style: tt.labelSmall?.copyWith(
                        color: widget.accent, fontWeight: FontWeight.w600)),
                Text(_pos(line.start),
                    style: tt.labelSmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.4))),
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(line.text, style: tt.bodyMedium)),
          ]),
        ),
      ));
    }
    if (_transcribing) {
      out.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const SizedBox.square(
              dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(l.sleepSpotTranscribing('${_done + 1}', '$_total'),
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ]),
      ));
    } else if (missing.isNotEmpty) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _transcribe,
            icon: const Icon(Icons.record_voice_over_rounded, size: 18),
            label: Text(l.sleepSpotTranscribe),
          ),
        ),
      ));
    }
    out.add(Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _extend(earlier: false),
        icon: const Icon(Icons.expand_more_rounded),
        label: Text(l.sleepSpotLater),
      ),
    ));
    return out;
  }
}
