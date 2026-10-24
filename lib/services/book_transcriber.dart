import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show rootNavigatorKey;
import 'transcript_line_store.dart';
import 'transcription_service.dart';

/// Why a whole-book run stopped before the end.
enum BookTranscribeStop { user, battery, failed, unavailable }

/// Transcribes a whole book in the background, window after window, into the
/// same transcript cache the live transcript, read along and "Where did I fall
/// asleep?" read from. Parts already transcribed are skipped, so stopping and
/// starting again carries on where it left off.
///
/// Runs under a foreground notification and a CPU wake lock so it keeps going
/// with the screen off; meant for overnight on the charger. One book at a time.
class BookTranscriber extends ChangeNotifier {
  BookTranscriber._();
  static final BookTranscriber instance = BookTranscriber._();

  static const _window = 30.0;
  static const _notifId = 7342;
  static const _channelId = 'absorb_book_transcription';
  // Below this, off the charger, the run stops rather than drain the phone.
  static const _minBattery = 20;

  String? _itemId;
  String? _title;
  bool _running = false;
  bool _stopRequested = false;
  double _total = 0;
  double _covered = 0;
  double _position = 0;
  // Audio seconds actually run through the recognizer this session, and the
  // time it took, for the speed and the estimate.
  double _audioDone = 0;
  final Stopwatch _clock = Stopwatch();
  BookTranscribeStop? _lastStop;
  String? _lastStopItem;
  bool _finished = false;

  String? get itemId => _itemId;
  String? get title => _title;
  bool get running => _running;
  bool isRunningFor(String itemId) => _running && _itemId == itemId;
  double get totalSeconds => _total;
  double get coveredSeconds => _covered;
  double get fraction => _total > 0 ? (_covered / _total).clamp(0.0, 1.0) : 0;
  bool finishedFor(String itemId) => _finished && _lastStopItem == itemId;
  BookTranscribeStop? stopReasonFor(String itemId) =>
      _lastStopItem == itemId ? _lastStop : null;

  /// How many seconds of audio go through per second of work.
  double? get speed {
    final secs = _clock.elapsedMilliseconds / 1000.0;
    if (secs < 20 || _audioDone <= 0) return null;
    return _audioDone / secs;
  }

  Duration? get remaining {
    final s = speed;
    if (s == null || s <= 0) return null;
    final left = max(0.0, _total - _covered);
    return Duration(seconds: (left / s).round());
  }

  /// How much of [itemId] is transcribed already, 0..1, or null if unknown.
  Future<double?> coverage(String itemId) async {
    final total = await TranscriptionService.instance.bookDurationSeconds(itemId);
    if (total == null) return null;
    await TranscriptLineStore.instance.hydrate(itemId);
    return (TranscriptLineStore.instance.preparedSeconds(itemId) / total)
        .clamp(0.0, 1.0);
  }

  /// Start (or carry on) transcribing [itemId]. Returns false when it can't
  /// begin: another book is running, or the book's length is unknown.
  Future<bool> start(String itemId, String title) async {
    if (_running) return _itemId == itemId;
    final svc = TranscriptionService.instance;
    final total = await svc.bookDurationSeconds(itemId);
    if (total == null) {
      _lastStop = BookTranscribeStop.unavailable;
      _lastStopItem = itemId;
      notifyListeners();
      return false;
    }
    _itemId = itemId;
    _title = title;
    _total = total;
    _running = true;
    _stopRequested = false;
    _finished = false;
    _lastStop = null;
    _lastStopItem = itemId;
    _audioDone = 0;
    _clock
      ..reset()
      ..start();
    await TranscriptLineStore.instance.hydrate(itemId);
    _covered = TranscriptLineStore.instance.preparedSeconds(itemId);
    notifyListeners();
    unawaited(_run());
    return true;
  }

  void stop() {
    if (!_running) return;
    _stopRequested = true;
    notifyListeners();
  }

  Future<void> _run() async {
    final itemId = _itemId!;
    final svc = TranscriptionService.instance;
    final store = TranscriptLineStore.instance;
    await svc.setCpuWakeLock(true);
    await _notify(force: true);
    BookTranscribeStop? reason;
    var failures = 0;
    var lastBatteryCheck = DateTime(2000);
    _position = 0;
    try {
      while (_position < _total - 0.5) {
        if (_stopRequested) {
          reason = BookTranscribeStop.user;
          break;
        }
        // Skip what is already there.
        final covered = store.coveredUntil(itemId, _position);
        if (covered > _position + 1) {
          _position = covered;
          continue;
        }
        if (DateTime.now().difference(lastBatteryCheck).inMinutes >= 2) {
          lastBatteryCheck = DateTime.now();
          final b = await svc.batteryStatus();
          if (b != null && !b.charging && b.level < _minBattery) {
            reason = BookTranscribeStop.battery;
            break;
          }
        }
        // Windows never cross a file boundary.
        var window = min(_window, _total - _position);
        final boundary = svc.trackBoundaryBetween(itemId, _position, _position + window);
        if (boundary != null) window = boundary - _position;
        if (window < 0.5) {
          _position += max(window, 0.5);
          continue;
        }
        try {
          final words = await svc.transcribeWindowSegments(
            itemId: itemId,
            startSeconds: _position,
            windowSeconds: window,
            feature: TranscriptionFeature.bookmarks,
          );
          await store.addLines(itemId, transcriptLinesFromWords(words, _position));
          failures = 0;
        } on TranscriptionException catch (e) {
          if (e.kind == TranscriptionError.busy) {
            // The live transcript or a bookmark has the engine; wait a turn.
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          if (e.kind != TranscriptionError.empty) {
            debugPrint('[BookTranscribe] window at ${_position.toStringAsFixed(0)}s failed: $e');
            if (e.kind == TranscriptionError.disabled ||
                e.kind == TranscriptionError.modelMissing ||
                ++failures >= 5) {
              reason = BookTranscribeStop.failed;
              break;
            }
          }
        } catch (e) {
          debugPrint('[BookTranscribe] window at ${_position.toStringAsFixed(0)}s failed: $e');
          if (++failures >= 5) {
            reason = BookTranscribeStop.failed;
            break;
          }
        }
        _audioDone += window;
        _position += window;
        _covered = store.preparedSeconds(itemId);
        notifyListeners();
        await _notify();
      }
    } finally {
      _running = false;
      _clock.stop();
      _covered = store.preparedSeconds(itemId);
      _finished = reason == null;
      _lastStop = reason;
      _lastStopItem = itemId;
      await svc.setCpuWakeLock(false);
      await _finishNotification();
      debugPrint('[BookTranscribe] $itemId stopped: ${reason ?? 'finished'} '
          '(${(fraction * 100).toStringAsFixed(1)}% covered, '
          'speed ${speed?.toStringAsFixed(1) ?? '-'}x)');
      notifyListeners();
    }
  }

  // Notification

  bool _foreground = false;
  DateTime _lastNotify = DateTime(2000);

  AppLocalizations? _l() {
    final ctx = rootNavigatorKey.currentContext;
    return ctx != null ? AppLocalizations.of(ctx) : null;
  }

  AndroidNotificationDetails _details({required bool ongoing, int? progress}) =>
      AndroidNotificationDetails(
        _channelId,
        _l()?.bookTranscribeChannel ?? 'Book transcription',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: ongoing,
        autoCancel: !ongoing,
        onlyAlertOnce: true,
        showProgress: progress != null,
        maxProgress: 1000,
        progress: progress ?? 0,
        icon: 'drawable/ic_notification',
      );

  String _body() {
    final pct = (fraction * 100).toStringAsFixed(0);
    final left = remaining;
    if (left == null) return '$pct%';
    final h = left.inHours;
    final m = left.inMinutes % 60;
    return '$pct% · ${h > 0 ? '${h}h ' : ''}${m}m';
  }

  Future<void> _notify({bool force = false}) async {
    if (!force && DateTime.now().difference(_lastNotify).inSeconds < 5) return;
    _lastNotify = DateTime.now();
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      final android = plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final title = _l()?.bookTranscribeNotifTitle(_title ?? '') ?? 'Transcribing $_title';
      final details = _details(ongoing: true, progress: (fraction * 1000).round());
      if (android != null && !_foreground) {
        await android.createNotificationChannel(AndroidNotificationChannel(
          _channelId,
          _l()?.bookTranscribeChannel ?? 'Book transcription',
          importance: Importance.low,
          showBadge: false,
        ));
        try {
          await android.startForegroundService(_notifId, title, _body(),
              notificationDetails: details);
          _foreground = true;
          return;
        } catch (e) {
          debugPrint('[BookTranscribe] foreground service failed: $e');
        }
      }
      await plugin.show(_notifId, title, _body(), NotificationDetails(android: details));
    } catch (e) {
      debugPrint('[BookTranscribe] notification error: $e');
    }
  }

  Future<void> _finishNotification() async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      if (_foreground) {
        await plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.stopForegroundService();
        _foreground = false;
      }
      await plugin.cancel(_notifId);
      if (_lastStop == BookTranscribeStop.user) return;
      final l = _l();
      final title = _title ?? '';
      final text = switch (_lastStop) {
        null => l?.bookTranscribeDoneNotif(title) ?? 'Transcribed $title',
        BookTranscribeStop.battery =>
          l?.bookTranscribeBatteryNotif ?? 'Stopped: battery low. Plug in to carry on.',
        _ => l?.bookTranscribeFailedNotif ?? 'Transcription stopped after repeated errors.',
      };
      await plugin.show(_notifId, title, text,
          NotificationDetails(android: _details(ongoing: false)));
    } catch (_) {}
  }
}
