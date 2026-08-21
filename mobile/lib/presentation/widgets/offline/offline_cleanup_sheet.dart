/// immich-sync fork — where space is taken back (FORK.md §3.6). Apart from the storage screen on purpose: that one
/// reports, this one removes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_reclaim_dialog.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

Future<void> showOfflineCleanupSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => const _CleanupSheet(),
);

class _CleanupSheet extends ConsumerStatefulWidget {
  const _CleanupSheet();

  @override
  ConsumerState<_CleanupSheet> createState() => _CleanupSheetState();
}

class _CleanupSheetState extends ConsumerState<_CleanupSheet> {
  /// Nothing ticked, so the sheet opens inert.
  var _what = OfflineReclaim.nothing;

  /// Everything the sheet has to say about the current choice, from the same queries the deletion runs: the total and
  /// its consequences, and what each ticked cell actually gives up.
  Future<_Answer>? _answer;

  void _set(OfflineReclaim what) {
    setState(() {
      _what = what;
      _answer = what.isEmpty ? null : _measure(what);
    });
  }

  Future<_Answer> _measure(OfflineReclaim what) async {
    final service = ref.read(offlineSyncServiceProvider);
    final (plan, covered) = await (service.reclaimPlan(what: what), service.reclaimBytesByCell(what)).wait;
    return (plan: plan, covered: covered);
  }

  @override
  Widget build(BuildContext context) {
    final storage = ref.watch(offlineStorageProvider).valueOrNull ?? OfflineStorage.empty;

    return SafeArea(
      // Scrollable: the sheet grows with the text-scale setting, and a button
      // pushed off the bottom is a sheet that cannot do anything.
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Free up space', style: context.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Removes copies from this phone only. Nothing on your server changes.',
                    style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),

            FutureBuilder<_Answer>(
              future: _answer,
              builder: (context, snapshot) {
                final answer = snapshot.connectionState == ConnectionState.done ? snapshot.data : null;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final band in OfflineReclaimBand.values)
                      _BandSection(
                        band: band,
                        storage: storage,
                        what: _what,
                        covered: answer?.covered,
                        locked: _locked(band, storage),
                        onToggle: _toggle,
                      ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _Footer(
                        what: _what,
                        plan: answer?.plan,
                        counting: _answer != null && snapshot.connectionState != ConnectionState.done,
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _toggle(OfflineReclaimBand band, OfflineReclaimKind kind, {required bool on}) {
    var next = _what.toggled(band, kind, on: on);
    // Untick the band that was only reachable because everything above it was
    // going: leaving it ticked would hold a choice the rows no longer offer.
    if (!on && band != OfflineReclaimBand.maintained) {
      next = next.without(OfflineReclaimBand.maintained);
    }
    _set(next);
  }

  /// Whether a band can be touched at all.
  bool _locked(OfflineReclaimBand band, OfflineStorage storage) {
    if (band != OfflineReclaimBand.maintained) {
      return false;
    }
    return OfflineReclaimBand.values.any(
      (other) =>
          other != OfflineReclaimBand.maintained &&
          OfflineReclaimKind.values.any((kind) => storage.bytesFor(other, kind) > 0 && !_what.has(other, kind)),
    );
  }
}

/// Everything one choice measures out to.
typedef _Answer = ({OfflineReclaimPlan plan, Map<OfflineReclaimCell, int> covered});

/// One band: what it is, what it holds, and a row per kind of file.
class _BandSection extends StatelessWidget {
  const _BandSection({
    required this.band,
    required this.storage,
    required this.what,
    required this.covered,
    required this.locked,
    required this.onToggle,
  });

  final OfflineReclaimBand band;
  final OfflineStorage storage;
  final OfflineReclaim what;

  /// What each ticked cell actually gives up, measured rather than assumed — null while the measuring is still in
  /// flight.
  final Map<OfflineReclaimCell, int>? covered;

  /// Whether this band is out of reach for now, and why is said where the rows are rather than where the button is.
  final bool locked;

  final void Function(OfflineReclaimBand, OfflineReclaimKind, {required bool on}) onToggle;

  @override
  Widget build(BuildContext context) {
    final total = storage.bandBytes(band);
    final tint = locked
        ? context.colorScheme.onSurfaceVariant
        : (band.pauses ? context.colorScheme.error : context.colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (band.pauses) ...[
                Icon(locked ? Icons.lock_outline : Icons.warning_amber_rounded, size: 16, color: tint),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  _title(band),
                  style: context.textTheme.labelMedium?.copyWith(color: tint, letterSpacing: 0.6),
                ),
              ),
              Text(formatBytes(total), style: context.textTheme.labelMedium?.copyWith(color: tint)),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            locked ? 'Available once everything above is selected.' : _explainer(band),
            style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
          for (final kind in OfflineReclaimKind.values)
            _KindRow(
              label: _kindLabel(kind),
              enabled: !locked,
              bytes: storage.bytesFor(band, kind),
              // Only meaningful once the cell is ticked and measured. A ticked cell missing from the answer gave up
              // nothing at all, which is the case most worth showing, so it reads as zero rather than as unknown.
              going: what.has(band, kind) && covered != null ? (covered![(band, kind)] ?? 0) : null,
              holding: _holding(band, what),
              selected: what.has(band, kind),
              onSelected: (on) => onToggle(band, kind, on: on),
            ),
        ],
      ),
    );
  }

  static String _title(OfflineReclaimBand band) => switch (band) {
    OfflineReclaimBand.spares => 'SPARES',
    OfflineReclaimBand.maintained => 'KEPT BY YOUR SETTINGS',
  };

  static String _explainer(OfflineReclaimBand band) => switch (band) {
    OfflineReclaimBand.spares => 'Left by a change to your settings, or saved by hand. Nothing re-downloads these.',
    OfflineReclaimBand.maintained => 'Removing these pauses downloading. Resume gets them back.',
  };

  /// The rows that would have to go with them, named from the full-size kinds this band is leaving behind.
  static String _holding(OfflineReclaimBand band, OfflineReclaim what) {
    final videos = !what.has(band, OfflineReclaimKind.videos);
    final photos = !what.has(band, OfflineReclaimKind.originals);
    // Quoted and joined with a plus: these are the labels of the rows above,
    // and reading them as labels is what makes the instruction followable.
    if (videos && photos) {
      return '"Videos" + "Full-size photos"';
    }
    return videos ? '"Videos"' : '"Full-size photos"';
  }

  static String _kindLabel(OfflineReclaimKind kind) => switch (kind) {
    OfflineReclaimKind.videos => 'Videos',
    OfflineReclaimKind.originals => 'Full-size photos',
    OfflineReclaimKind.previews => 'Previews & thumbnails',
  };
}

/// One kind of file within one band, on a line of its own. A cell holding nothing stays visible and inert rather than
/// disappearing: a grid whose rows come and go cannot be learned, and `0 B` is an answer.
class _KindRow extends StatelessWidget {
  const _KindRow({
    required this.label,
    required this.bytes,
    required this.going,
    required this.holding,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final String label;
  final int bytes;
  final int? going;

  /// The rows that have to go too, named as they are labelled above.
  final String holding;

  final bool selected;
  final bool enabled;
  final void Function(bool) onSelected;

  @override
  Widget build(BuildContext context) {
    final held = going == null ? 0 : bytes - going!;
    return CheckboxListTile(
      value: selected,
      onChanged: bytes <= 0 || !enabled ? null : (value) => onSelected(value ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Row(
        children: [
          Expanded(child: Text(label, style: context.textTheme.bodyMedium)),
          Text(
            held > 0 ? '${formatBytes(going!)} of ${formatBytes(bytes)}' : formatBytes(bytes),
            style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
      subtitle: held > 0
          ? Text(
              'Select $holding for the other ${formatBytes(held)}.',
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.tertiary),
            )
          : null,
    );
  }
}

/// The button that spends the choice.
class _Footer extends ConsumerWidget {
  const _Footer({required this.what, required this.plan, required this.counting});

  final OfflineReclaim what;

  /// Null until the query above has answered, which is also when the button is allowed to quote a figure: the number on
  /// it is the number the deletion takes, so it never shows the previous answer while the next is on its way.
  final OfflineReclaimPlan? plan;
  final bool counting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = plan?.bytes ?? 0;
    final ready = bytes > 0 && !counting;

    return FilledButton.tonal(
      onPressed: ready ? () => unawaited(_free(context, ref)) : null,
      style: what.pauses && ready
          ? FilledButton.styleFrom(
              foregroundColor: context.colorScheme.onErrorContainer,
              backgroundColor: context.colorScheme.errorContainer,
            )
          : null,
      child: Text(
        switch ((what.isEmpty, counting, bytes > 0)) {
          (true, _, _) => 'Nothing selected',
          (false, true, _) => 'Adding up…',
          (false, false, false) => 'Nothing to free',
          (false, false, true) =>
            what.pauses ? 'Free ${formatBytes(bytes)} and pause' : 'Free ${formatBytes(bytes)}',
        },
      ),
    );
  }

  Future<void> _free(BuildContext context, WidgetRef ref) async {
    final navigator = Navigator.of(context);
    // Closed once it has actually removed something — the choice it was showing has been spent.
    if (await confirmFreeUpSpace(context, ref, what: what) && navigator.mounted) {
      navigator.pop();
    }
  }
}
