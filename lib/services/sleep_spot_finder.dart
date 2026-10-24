import 'playback_history_service.dart';

/// A moment in the book tied to the wall clock: "at 23:41 you were here".
class SleepSpot {
  final DateTime at;
  final double positionSeconds;
  /// The history entry this spot came from, when it came from one.
  final PlaybackEvent? event;
  const SleepSpot(this.at, this.positionSeconds, {this.event});
}

/// One stretch of the timeline between two history entries. While playing
/// the position moves linearly from [p0] to [p1]; while paused they match.
class _Segment {
  final DateTime t0, t1;
  final double p0, p1;
  final bool playing;
  const _Segment(this.t0, this.t1, this.p0, this.p1, this.playing);

  double positionAt(DateTime t) {
    final span = t1.difference(t0).inMilliseconds;
    if (span <= 0 || !playing) return p1;
    final f = (t.difference(t0).inMilliseconds / span).clamp(0.0, 1.0);
    return p0 + (p1 - p0) * f;
  }
}

/// Rebuilds where the book was at any wall-clock moment from the per-book
/// playback history, so someone who dozed off can say "I remember 23:40" or
/// "I last shook the phone" instead of hunting with the scrubber.
///
/// The history holds play, pause, seek and the regular server syncs, each
/// with its time and position. Between two of them playback either sat still
/// or ran at the listening speed, which is enough to fill in the gaps.
class SleepSpotFinder {
  /// Oldest first.
  final List<PlaybackEvent> events;
  final List<_Segment> _segments;

  SleepSpotFinder._(this.events, this._segments);

  /// [history] in any order (the history service hands it back newest first).
  /// [speed] is the book's speed, used until the history says otherwise.
  /// [livePosition] is the player's position right now when this book is the
  /// one loaded, and [livePlaying] whether it is playing at this moment.
  factory SleepSpotFinder(
    List<PlaybackEvent> history, {
    double speed = 1.0,
    double? livePosition,
    bool livePlaying = false,
    DateTime? now,
  }) {
    final events = [...history]
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return SleepSpotFinder._(
      events,
      _buildSegments(events, speed, livePosition, livePlaying, now ?? DateTime.now()),
    );
  }

  bool get isEmpty => events.isEmpty;

  // Seeks log the spot they left from, so where they landed only shows up in
  // the next entry. Everything else logs where playback is after it.
  static bool _landingUnknown(PlaybackEventType t) =>
      t == PlaybackEventType.seek || t == PlaybackEventType.autoRewind;

  static bool _stops(PlaybackEvent e) {
    switch (e.type) {
      case PlaybackEventType.pause:
      case PlaybackEventType.bookFinished:
      case PlaybackEventType.sleepTimer:
        return true;
      case PlaybackEventType.sessionEnd:
        return !(e.detail ?? '').contains('hot-swap');
      default:
        return false;
    }
  }

  static double? _parseSpeed(String? detail) {
    if (detail == null) return null;
    final m = RegExp(r'([0-9]+(?:\.[0-9]+)?)x').firstMatch(detail);
    final v = m == null ? null : double.tryParse(m.group(1)!);
    return (v != null && v > 0) ? v : null;
  }

  static List<_Segment> _buildSegments(
    List<PlaybackEvent> events,
    double fallbackSpeed,
    double? livePosition,
    bool livePlaying,
    DateTime now,
  ) {
    final segs = <_Segment>[];
    var playing = false;
    var speed = fallbackSpeed > 0 ? fallbackSpeed : 1.0;
    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      if (e.type == PlaybackEventType.play) playing = true;
      if (_stops(e)) playing = false;
      if (e.type == PlaybackEventType.speedChange) {
        speed = _parseSpeed(e.detail) ?? speed;
      }

      final isLast = i == events.length - 1;
      final DateTime t1;
      final double? end;
      if (!isLast) {
        t1 = events[i + 1].timestamp;
        end = events[i + 1].positionSeconds;
      } else {
        // Run the last stretch up to now only when the player can vouch for
        // where it is; otherwise the timeline stops at the last entry.
        if (livePosition == null) break;
        t1 = now.isAfter(e.timestamp) ? now : e.timestamp;
        end = livePosition;
        if (!livePlaying) playing = false;
      }
      final t0 = e.timestamp;
      final secs = t1.difference(t0).inMilliseconds / 1000.0;
      final unknownStart = _landingUnknown(e.type);

      if (!playing) {
        final p = unknownStart ? end : e.positionSeconds;
        segs.add(_Segment(t0, t1, p, p, false));
        continue;
      }
      if (unknownStart) {
        // Count back from where the next entry found it.
        final p0 = (end - secs * speed).clamp(0.0, end);
        segs.add(_Segment(t0, t1, p0, end, true));
        continue;
      }
      final p0 = e.positionSeconds;
      final rate = secs > 0 ? (end - p0) / secs : 0.0;
      // Anything from a crawl to the fastest speed setting reads as steady
      // playback. The speed may not be in the history at all, so a long
      // enough steady stretch also tells us what it really was.
      if (secs <= 0 || (rate >= 0.25 && rate <= 5.0)) {
        if (secs >= 60) speed = rate;
        segs.add(_Segment(t0, t1, p0, end, true));
        continue;
      }
      // The next entry doesn't line up with steady playback - the app was
      // likely killed mid-play, or playback stalled. Play on at speed until
      // the position it was next seen at, then hold there.
      final target = end > p0 ? end : p0;
      final reachSecs = (target - p0) / speed;
      if (reachSecs <= 0 || reachSecs >= secs) {
        final p1 = p0 + secs * speed;
        segs.add(_Segment(t0, t1, p0, p1 < target ? p1 : target, true));
      } else {
        final mid = t0.add(Duration(milliseconds: (reachSecs * 1000).round()));
        segs.add(_Segment(t0, mid, p0, target, true));
        segs.add(_Segment(mid, t1, target, target, false));
      }
    }
    return segs;
  }

  /// Where the book was at [t], or null when the history doesn't reach back
  /// that far.
  double? positionAt(DateTime t) {
    if (_segments.isEmpty || t.isBefore(_segments.first.t0)) return null;
    for (final s in _segments) {
      if (!t.isAfter(s.t1)) return s.positionAt(t);
    }
    return _segments.last.p1;
  }

  /// Earliest and latest moment the timeline covers.
  DateTime? get coveredFrom => _segments.isEmpty ? null : _segments.first.t0;
  DateTime? get coveredUntil => _segments.isEmpty ? null : _segments.last.t1;

  /// When playback passed [position], picking the pass closest to [near]
  /// (the same stretch of a book can be played on several nights).
  DateTime? timeAtPosition(double position, {DateTime? near}) {
    DateTime? best;
    int? bestGap;
    final ref = near ?? DateTime.now();
    for (final s in _segments) {
      if (!s.playing || s.p1 <= s.p0) continue;
      if (position < s.p0 || position > s.p1) continue;
      final f = (position - s.p0) / (s.p1 - s.p0);
      final t = s.t0.add(Duration(
          milliseconds: (s.t1.difference(s.t0).inMilliseconds * f).round()));
      final gap = t.difference(ref).inMilliseconds.abs();
      if (bestGap == null || gap < bestGap) {
        bestGap = gap;
        best = t;
      }
    }
    return best;
  }

  static bool _isAwakeSignal(PlaybackEvent e) {
    switch (e.type) {
      case PlaybackEventType.awake:
      case PlaybackEventType.seek:
      case PlaybackEventType.skipForward:
      case PlaybackEventType.skipBackward:
      case PlaybackEventType.speedChange:
        return true;
      case PlaybackEventType.play:
        // Resumes the app does by itself say nothing about the listener.
        final d = e.detail ?? '';
        return !(d.contains('Auto-resumed') ||
            d.contains('rebuilt') ||
            d.contains('Switched'));
      default:
        return false;
    }
  }

  /// The latest time the sleep timer paused playback, or failing that the
  /// latest pause of any kind.
  PlaybackEvent? get lastSleep {
    PlaybackEvent? anyPause;
    for (final e in events.reversed) {
      if (e.type == PlaybackEventType.sleepTimer) return e;
      if (anyPause == null && e.type == PlaybackEventType.pause) anyPause = e;
    }
    return anyPause;
  }

  /// The last thing only an awake listener does (shaking to extend the timer,
  /// snoozing it, pressing play, skipping...) before the last sleep pause.
  /// Its position is where the book was just after it, since a skip or a seek
  /// moves you somewhere new and you heard on from there.
  SleepSpot? lastAwake() {
    final sleep = lastSleep;
    final limit = sleep?.timestamp;
    for (final e in events.reversed) {
      if (limit != null && e.timestamp.isAfter(limit)) continue;
      if (!_isAwakeSignal(e)) continue;
      final at = e.timestamp.add(const Duration(seconds: 1));
      final pos = positionAt(at) ?? e.positionSeconds;
      return SleepSpot(e.timestamp, pos, event: e);
    }
    return null;
  }

  /// [time] on the most recent day the history can place it.
  SleepSpot? spotAtClockTime(int hour, int minute, {DateTime? now}) {
    final today = now ?? DateTime.now();
    for (var back = 0; back < 14; back++) {
      final day = today.subtract(Duration(days: back));
      final t = DateTime(day.year, day.month, day.day, hour, minute);
      if (t.isAfter(today)) continue;
      final from = coveredFrom;
      if (from == null || t.isBefore(from)) return null;
      final pos = positionAt(t);
      if (pos != null) return SleepSpot(t, pos);
    }
    return null;
  }
}
