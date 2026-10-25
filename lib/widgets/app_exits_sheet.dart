import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';
import 'absorbing_shared.dart';

const _channel = MethodChannel('com.barnabas.absorb/transcription');

/// Android's own record of how the app's recent processes ended (crash, out
/// of memory, killed by the system...). When playback stops in the night with
/// nothing in the history, this is where the reason is.
void showAppExitsSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, controller) => _AppExitsBody(controller: controller),
    ),
  );
}

class _AppExitsBody extends StatelessWidget {
  final ScrollController controller;
  const _AppExitsBody({required this.controller});

  static String _reason(int r) => switch (r) {
        1 => 'Exited by itself',
        2 => 'Killed by a signal',
        3 => 'Low memory',
        4 => 'Crash (Java/Kotlin)',
        5 => 'Crash (native code)',
        6 => 'Not responding (ANR)',
        7 => 'Failed to start',
        8 => 'Permission changed',
        9 => 'Used too much resources',
        10 => 'Closed by you',
        11 => 'Force stopped',
        12 => 'A dependency died',
        13 => 'Other',
        14 => 'Frozen app killed',
        15 => 'Package changed',
        16 => 'App updated',
        _ => 'Unknown ($r)',
      };

  static String _importance(int i) {
    if (i <= 100) return 'on screen';
    if (i <= 125) return 'foreground service';
    if (i <= 230) return 'perceptible';
    if (i <= 300) return 'service';
    if (i <= 400) return 'cached';
    return 'gone';
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final raw = await _channel.invokeListMethod<dynamic>('exitHistory') ?? const [];
    return [for (final e in raw) Map<String, dynamic>.from(e as Map)];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).bottomSheetTheme.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _load(),
        builder: (context, snap) {
          final exits = snap.data;
          return ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Text(l.appExitsTitle,
                  textAlign: TextAlign.center,
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(l.appExitsHint,
                  textAlign: TextAlign.center,
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 12),
              if (snap.hasError)
                Text('${snap.error}', style: tt.bodySmall)
              else if (exits == null)
                const Center(child: CircularProgressIndicator(strokeWidth: 2))
              else if (exits.isEmpty)
                Text(l.appExitsNone, textAlign: TextAlign.center)
              else
                for (final e in exits)
                  Builder(builder: (context) {
                    final at = DateTime.fromMillisecondsSinceEpoch(
                        (e['time'] as num).toInt());
                    final use24 = MediaQuery.of(context).alwaysUse24HourFormat;
                    final clock = MaterialLocalizations.of(context).formatTimeOfDay(
                        TimeOfDay.fromDateTime(at),
                        alwaysUse24HourFormat: use24);
                    final reason = (e['reason'] as num).toInt();
                    final bad = const {2, 3, 4, 5, 6, 9, 14}.contains(reason);
                    final rss = ((e['rssKb'] as num?) ?? 0) ~/ 1024;
                    final desc = (e['description'] as String?)?.trim();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                          bad ? Icons.error_outline_rounded : Icons.logout_rounded,
                          color: bad ? cs.error : cs.onSurfaceVariant),
                      title: Text('${dateLabel(at, l)} $clock · ${_reason(reason)}'),
                      subtitle: Text(
                        [
                          'while ${_importance((e['importance'] as num).toInt())}',
                          if (rss > 0) 'memory $rss MB',
                          if (desc != null && desc.isNotEmpty) desc,
                        ].join(' · '),
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    );
                  }),
            ],
          );
        },
      ),
    );
  }
}
