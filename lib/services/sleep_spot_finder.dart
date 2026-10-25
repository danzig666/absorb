import 'playback_history_service.dart';

/// A moment in the book tied to the wall clock: "at 23:41 you were here".
class SleepSpot {
  final DateTime at;
  final double positionSeconds;
  /// The history entry this spot came from, when it came from one.
  final PlaybackEvent? event;
  const SleepSpot(this.at, this.positionSeconds, {this.event});
}

/// One stretch of listening: from pressing play to whatever stopped it.
class ListeningSession {
  final DateTime start;
  final DateTime end;
  final double startPosition;
  final double endPosition;
  /// What ended it (sleep timer, pause...), or null while it is still going
  /// or when it stopped without a pause being recorded.
  final PlaybackEvent? endEvent;
  /// Playing right now.
  final bool stillPlaying;
  /// The last thing only an awake listener does inside it.
  final SleepSpot? lastAwake;
  /// Started by a headphone or other media button press.
  final bool fromMediaButton;
  /// Short and after a long silence: most likely a button pressed in the
  /// night, not real listening.
  final bool likelyAccidental;

  const ListeningSession({
    required this.start,
    required this.end,
    required this.startPosition,
    required this.endPosition,
    required this.endEvent,
    this.stillPlaying = false,
    required this.lastAwake,
    required this.fromMediaButton,
    required this.likelyAccidental,
  });

  Duration get length => end.difference(start);
  bool get endedBySleepTimer => endEvent?.type == PlaybackEventType.sleepTimer;

  /// Where to go back to for this session: just after the last awake sign,
  /// or failing that where it started.
  SleepSpot get spot => lastAwake ?? SleepSpot(start, startPosition);
}

/// One stretch of the timeline between two history entries. While playing
/// the position moves linearly from [p0] to [p1]; while paused they match.
class _Segment {
  final DateTime t0, t1;
  final double p0, p1;
  final bool playing;
  /// The history entry at [t1], or null when the stretch runs to now or
  /// ends at a point worked out between entries.
  final PlaybackEvent? to;
  const _Segment(this.t0, this.t1, this.p0, this.p1, this.playing, [this.to]);

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
  final bool _livePlaying;

  SleepSpotFinder._(this.events, this._segments, this._livePlaying);

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
    // Stable by time: entries logged in the same millisecond (the sleep
    // timer's own entry and the pause it causes) keep their order.
    final indexed = [for (var i = 0; i < history.length; i++) (i, history[i])];
    final newestFirst = history.length > 1 &&
        history.first.timestamp.isAfter(history.last.timestamp);
    indexed.sort((a, b) {
      final c = a.$2.timestamp.compareTo(b.$2.timestamp);
      if (c != 0) return c;
      return newestFirst ? b.$1.compareTo(a.$1) : a.$1.compareTo(b.$1);
    });
    final events = [for (final e in indexed) e.$2];
    return SleepSpotFinder._(
      events,
      _buildSegments(events, speed, livePosition, livePlaying, now ?? DateTime.now()),
      livePosition != null && livePlaying,
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
      final PlaybackEvent? to = isLast ? null : events[i + 1];
      if (!isLast) {
        t1 = events[i + 1].timestamp;
        end = events[i + 1].positionSeconds;
        // Not every start or stop makes it into the history (a fresh
        // streaming session, a pause the system made). The position says it
        // anyway: moving at a listening pace between two entries means
        // playing, standing still means not.
        if (e.type != PlaybackEventType.play &&
            !_stops(e) &&
            !_landingUnknown(e.type)) {
          final secs = t1.difference(e.timestamp).inMilliseconds / 1000.0;
          final delta = end - e.positionSeconds;
          if (secs >= 10) {
            final rate = delta / secs;
            if (rate >= 0.25 && rate <= 5.0) {
              playing = true;
            } else if (delta.abs() < (secs * 0.05 > 2 ? secs * 0.05 : 2)) {
              playing = false;
            }
          }
        }
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
        segs.add(_Segment(t0, t1, p, p, false, to));
        continue;
      }
      if (unknownStart) {
        // Count back from where the next entry found it.
        final p0 = (end - secs * speed).clamp(0.0, end);
        segs.add(_Segment(t0, t1, p0, end, true, to));
        continue;
      }
      final p0 = e.positionSeconds;
      final rate = secs > 0 ? (end - p0) / secs : 0.0;
      // Anything from a crawl to the fastest speed setting reads as steady
      // playback. The speed may not be in the history at all, so a long
      // enough steady stretch also tells us what it really was.
      if (secs <= 0 || (rate >= 0.25 && rate <= 5.0)) {
        if (secs >= 60) speed = rate;
        segs.add(_Segment(t0, t1, p0, end, true, to));
        continue;
      }
      // The next entry doesn't line up with steady playback - the app was
      // likely killed mid-play, or playback stalled. Play on at speed until
      // the position it was next seen at, then hold there.
      final target = end > p0 ? end : p0;
      final reachSecs = (target - p0) / speed;
      if (reachSecs <= 0 || reachSecs >= secs) {
        final p1 = p0 + secs * speed;
        segs.add(_Segment(t0, t1, p0, p1 < target ? p1 : target, true, to));
      } else {
        final mid = t0.add(Duration(milliseconds: (reachSecs * 1000).round()));
        segs.add(_Segment(t0, mid, p0, target, true));
        segs.add(_Segment(mid, t1, target, target, false, to));
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

  // A session shorter than this, after at least [_accidentGap] of silence,
  // reads as a button pressed by accident.
  static const _accidentLength = Duration(minutes: 5);
  static const _accidentGap = Duration(minutes: 30);

  /// Listening sessions, newest first, going back [within]: each unbroken
  /// run of playback on the timeline, however it started or stopped.
  List<ListeningSession> sessions({
    Duration within = const Duration(days: 7),
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(within);
    final segs = _segments;
    final out = <ListeningSession>[];
    DateTime? prevEnd;
    var i = 0;
    while (i < segs.length) {
      if (!segs[i].playing) {
        i++;
        continue;
      }
      // Run on through playing stretches, and through a pause too short to
      // be anything but a hiccup.
      var k = i;
      while (k + 1 < segs.length) {
        final next = segs[k + 1];
        if (next.playing) {
          k++;
        } else if (next.t1.difference(next.t0).inSeconds < 2 &&
            k + 2 < segs.length &&
            segs[k + 2].playing) {
          k += 2;
        } else {
          break;
        }
      }
      final first = segs[i];
      final last = segs[k];
      final start = first.t0;
      final end = last.t1;
      final stopper = last.to != null && _stops(last.to!) ? last.to : null;
      final still = last.to == null && k == segs.length - 1 && _livePlaying;

      PlaybackEvent? awake;
      var laterSigns = 0;
      var fromButton = false;
      final from = start.subtract(const Duration(seconds: 5));
      for (final e in events) {
        if (e.timestamp.isBefore(from.subtract(const Duration(seconds: 1)))) continue;
        if (e.timestamp.isAfter(end)) break;
        if (e.type == PlaybackEventType.clickDebounce &&
            !(e.detail ?? '').contains('suppressed') &&
            e.timestamp.difference(start).inSeconds.abs() <= 3) {
          fromButton = true;
        }
        if (e.timestamp.isBefore(from) || !_isAwakeSignal(e)) continue;
        if (e.timestamp.difference(start).inSeconds > 5) laterSigns++;
        awake = e;
      }
      SleepSpot? spot;
      if (awake != null) {
        final at = awake.timestamp.add(const Duration(seconds: 1));
        spot = SleepSpot(awake.timestamp, positionAt(at) ?? awake.positionSeconds,
            event: awake);
      }

      // After a long silence, either too short to be real listening, or
      // started from the headphones and never touched again (an automatic
      // sleep timer can keep such a press playing for half an hour).
      final gap = prevEnd == null ? null : start.difference(prevEnd);
      final afterSilence = gap == null || gap > _accidentGap;
      final accidental = afterSilence &&
          (end.difference(start) < _accidentLength ||
              (fromButton && laterSigns == 0));
      if (!start.isBefore(cutoff)) {
        out.add(ListeningSession(
          start: start,
          end: end,
          startPosition: first.p0,
          endPosition: last.p1,
          endEvent: stopper,
          stillPlaying: still,
          lastAwake: spot,
          fromMediaButton: fromButton,
          likelyAccidental: accidental,
        ));
      }
      prevEnd = end;
      i = k + 1;
    }
    return out.reversed.toList();
  }

  /// The session to offer first: the newest one that looks like real
  /// listening, else simply the newest.
  ListeningSession? likelySleepSession({DateTime? now}) {
    final all = sessions(now: now);
    for (final s in all) {
      if (!s.likelyAccidental) return s;
    }
    return all.isEmpty ? null : all.first;
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
