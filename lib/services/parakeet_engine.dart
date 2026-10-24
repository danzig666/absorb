import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

typedef TimedText = ({double start, double end, String text});

/// What one Parakeet run heard: the full text, each word with its timing,
/// and the words gathered into sentences. Times are seconds into the clip.
class ParakeetResult {
  final String text;
  final List<TimedText> words;
  final List<TimedText> sentences;
  const ParakeetResult(this.text, this.words, this.sentences);
}

/// NVIDIA Parakeet TDT 0.6B v3 in Moondream's 1.58-bit "Redux" form, run
/// through sherpa-onnx. The second speech engine next to Whisper: 25 European
/// languages, punctuation included, and much stronger than Whisper's small
/// models on anything that isn't English.
///
/// The model takes about a gigabyte of memory once loaded, so it lives in its
/// own isolate (decoding also blocks for seconds, which the UI thread must
/// never do) and is let go after a few idle minutes.
class ParakeetEngine {
  ParakeetEngine._();
  static final ParakeetEngine instance = ParakeetEngine._();

  // The sherpa-onnx packaging of moondream/parakeet-redux, one file at a time
  // so a broken download only costs that file. Sizes double as the
  // "complete" check.
  static const _baseUrl =
      'https://huggingface.co/cohearo/sherpa-onnx-nemo-parakeet-redux/resolve/main/';
  static const _files = <(String, int)>[
    ('tokens.txt', 93939),
    ('joiner.onnx', 25285351),
    ('decoder.onnx', 47249584),
    ('encoder.onnx', 343842409),
  ];
  static int get approxBytes => _files.fold(0, (n, f) => n + f.$2);

  static const _idleUnload = Duration(minutes: 3);

  bool _cancelDownload = false;

  /// Where the model lives, for tests that bring their own copy.
  @visibleForTesting
  static String? debugModelDir;

  Future<Directory> _dir() async {
    final override = debugModelDir;
    if (override != null) return Directory(override);
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}parakeet-redux');
  }

  Future<bool> isDownloaded() async {
    final dir = await _dir();
    for (final (name, size) in _files) {
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      if (!f.existsSync() || await f.length() != size) return false;
    }
    return true;
  }

  /// Fetch the model with progress (0..1). Files already complete are kept,
  /// so a retry after a dropped connection carries on where it stopped.
  Future<void> download({void Function(double progress)? onProgress}) async {
    _cancelDownload = false;
    final dir = await _dir();
    await dir.create(recursive: true);
    final total = approxBytes;
    var done = 0;
    final client = HttpClient();
    try {
      for (final (name, size) in _files) {
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        if (file.existsSync() && await file.length() == size) {
          done += size;
          onProgress?.call(done / total);
          continue;
        }
        final part = File('${file.path}.part');
        final request = await client.getUrl(Uri.parse('$_baseUrl$name'));
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode} for $name');
        }
        final sink = part.openWrite();
        var received = 0;
        try {
          await for (final chunk in response) {
            if (_cancelDownload) throw const _Cancelled();
            received += chunk.length;
            sink.add(chunk);
            onProgress?.call(((done + received) / total).clamp(0.0, 1.0));
          }
          await sink.flush();
          await sink.close();
        } catch (_) {
          await sink.close().catchError((_) {});
          if (part.existsSync()) await part.delete().catchError((_) => part);
          rethrow;
        }
        if (received != size) {
          if (part.existsSync()) await part.delete();
          throw HttpException('$name came down as $received bytes, expected $size');
        }
        if (file.existsSync()) await file.delete();
        await part.rename(file.path);
        done += size;
      }
      onProgress?.call(1.0);
      debugPrint('[Parakeet] model downloaded (${total ~/ (1024 * 1024)} MB)');
    } finally {
      client.close(force: false);
    }
  }

  void cancelActiveDownload() => _cancelDownload = true;

  Future<void> delete() async {
    await unload();
    final dir = await _dir();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  // The worker isolate holding the loaded model.

  SendPort? _worker;
  Isolate? _isolate;
  Future<SendPort>? _starting;
  int _workerThreads = 0;
  Timer? _idleTimer;

  Future<SendPort> _ensureWorker(int threads) async {
    final running = _worker;
    if (running != null && _workerThreads == threads) return running;
    if (running != null) await unload();
    return _starting ??= _spawn(threads).whenComplete(() => _starting = null);
  }

  Future<SendPort> _spawn(int threads) async {
    final dir = (await _dir()).path;
    final ready = ReceivePort();
    final watch = Stopwatch()..start();
    final isolate = await Isolate.spawn(
      _parakeetWorker,
      [ready.sendPort, dir, threads],
      debugName: 'parakeet',
    );
    final first = await ready.first;
    ready.close();
    if (first is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      throw Exception('Parakeet failed to load: $first');
    }
    debugPrint('[Parakeet] model loaded in ${watch.elapsedMilliseconds}ms '
        '(threads=$threads)');
    _isolate = isolate;
    _worker = first;
    _workerThreads = threads;
    return first;
  }

  /// Drop the loaded model and give its memory back.
  Future<void> unload() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final worker = _worker;
    final isolate = _isolate;
    _worker = null;
    _isolate = null;
    if (worker == null) return;
    worker.send('stop');
    // Belt and braces: if the worker is stuck mid-decode it goes anyway.
    Timer(const Duration(seconds: 5), () => isolate?.kill());
    debugPrint('[Parakeet] model unloaded');
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleUnload, unload);
  }

  /// Recognise a 16kHz mono WAV.
  Future<ParakeetResult> transcribeWav(String wavPath, {int threads = 4}) async {
    _idleTimer?.cancel();
    final worker = await _ensureWorker(threads);
    final reply = ReceivePort();
    worker.send([wavPath, reply.sendPort]);
    final msg = await reply.first;
    reply.close();
    _armIdle();
    if (msg is! Map) throw Exception('Parakeet failed: $msg');
    final tokens = (msg['tokens'] as List).cast<String>();
    final stamps = (msg['timestamps'] as List).cast<double>();
    final duration = msg['duration'] as double;
    final words = wordsFromTokens(tokens, stamps, duration);
    return ParakeetResult(
      (msg['text'] as String).trim(),
      words,
      sentencesFromWords(words),
    );
  }

  /// Parakeet reports sub-word tokens with their start times; a token that
  /// begins with a space (or SentencePiece's "▁") opens a new word, anything
  /// else - including punctuation - belongs to the word before it.
  @visibleForTesting
  static List<TimedText> wordsFromTokens(
      List<String> tokens, List<double> starts, double duration) {
    final n = tokens.length < starts.length ? tokens.length : starts.length;
    final out = <TimedText>[];
    var buf = StringBuffer();
    double? wordStart;
    var lastTokenStart = 0.0;
    void close(double nextStart) {
      final text = buf.toString().trim();
      if (wordStart != null && text.isNotEmpty) {
        // A word runs until the next one starts, but not across a long pause.
        var end = nextStart;
        if (end > lastTokenStart + 0.6) end = lastTokenStart + 0.6;
        if (end < wordStart!) end = wordStart!;
        out.add((start: wordStart!, end: end, text: text));
      }
      buf = StringBuffer();
      wordStart = null;
    }

    for (var i = 0; i < n; i++) {
      final tok = tokens[i];
      final t = starts[i];
      final opens = tok.startsWith(' ') || tok.startsWith('▁');
      if (opens && buf.isNotEmpty) close(t);
      wordStart ??= t;
      buf.write(tok.replaceAll('▁', ' '));
      lastTokenStart = t;
    }
    close(duration > lastTokenStart ? duration : lastTokenStart);
    return out;
  }

  /// Sentence-sized lines: a break after closing punctuation, at a pause, or
  /// once a line gets long.
  @visibleForTesting
  static List<TimedText> sentencesFromWords(List<TimedText> words) {
    final out = <TimedText>[];
    final buf = <String>[];
    double? start;
    var end = 0.0;
    void flush() {
      if (buf.isEmpty) return;
      out.add((start: start!, end: end, text: buf.join(' ')));
      buf.clear();
      start = null;
    }

    for (final w in words) {
      if (buf.isNotEmpty && w.start - end > 0.8) flush();
      start ??= w.start;
      buf.add(w.text);
      end = w.end;
      final len = buf.fold<int>(0, (n, t) => n + t.length + 1);
      if (RegExp(r'[.!?…]["”»)]*$').hasMatch(w.text) || len > 110) flush();
    }
    flush();
    return out;
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => 'cancelled';
}

/// Worker isolate: loads the model once, then answers [wavPath, replyPort]
/// requests until told to 'stop'.
void _parakeetWorker(List<Object?> args) {
  final ready = args[0] as SendPort;
  final dir = args[1] as String;
  final threads = args[2] as int;
  final sep = Platform.pathSeparator;
  sherpa.OfflineRecognizer recognizer;
  try {
    sherpa.initBindings();
    recognizer = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: '$dir${sep}encoder.onnx',
          decoder: '$dir${sep}decoder.onnx',
          joiner: '$dir${sep}joiner.onnx',
        ),
        tokens: '$dir${sep}tokens.txt',
        modelType: 'nemo_transducer',
        numThreads: threads,
        debug: false,
      ),
    ));
  } catch (e) {
    ready.send('$e');
    return;
  }
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((msg) {
    if (msg == 'stop') {
      recognizer.free();
      inbox.close();
      Isolate.exit();
    }
    final req = msg as List;
    final path = req[0] as String;
    final reply = req[1] as SendPort;
    try {
      final wave = sherpa.readWave(path);
      if (wave.sampleRate <= 0 || wave.samples.isEmpty) {
        reply.send('could not read $path');
        return;
      }
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
        recognizer.decode(stream);
        final r = recognizer.getResult(stream);
        reply.send({
          'text': r.text,
          'tokens': r.tokens,
          'timestamps': r.timestamps,
          'duration': wave.samples.length / wave.sampleRate,
        });
      } finally {
        stream.free();
      }
    } catch (e) {
      reply.send('$e');
    }
  });
}
