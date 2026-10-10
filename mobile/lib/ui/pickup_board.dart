import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import 'batch_sheet.dart' show openDonationByQr;
import 'expiry_widgets.dart' show ExpiryNote;
import 'location_picker.dart' show PickupRules, formatPickupTime;
import 'pickup_actions.dart';
import 'pickup_days.dart';
import 'pickup_map.dart';
import 'widgets.dart';

/// CSWS "Pickups" tab (Door to Door, Phase 1).
///
/// One list of every Door to Door donation that still has goods to collect,
/// grouped Overdue / Today / Tomorrow / This week / Later, soonest first.
/// Donors now choose pickup days instead of one time, so a donation whose
/// donor is home today shows under Today, tomorrow under Tomorrow, and so on.
/// The map button opens the same pickups on a map (pickup_map.dart).
/// Each card shows who donated, how to reach them, where to go, and what to
/// collect, with one-tap Call, Text and Navigate. "Open" goes to the usual
/// donation sheet to receive the goods (UC-CM1).
class PickupBoardScreen extends StatefulWidget {
  const PickupBoardScreen({super.key});

  @override
  State<PickupBoardScreen> createState() => _PickupBoardScreenState();
}

const _groups = [
  'Overdue',
  'Today',
  'Tomorrow',
  'This week',
  'Later',
  'No time set',
];

class _PickupBoardScreenState extends State<PickupBoardScreen> {
  late Future<ApiResult> _load = api.get('/donations/pickups');
  final _scroll = ScrollController();
  final _searchC = TextEditingController();
  String _search = '';
  String? _group; // null = all groups

  void _reload() => setState(() => _load = api.get('/donations/pickups'));

  @override
  void dispose() {
    _scroll.dispose();
    _searchC.dispose();
    super.dispose();
  }

  static DateTime? _when(Map b) =>
      DateTime.tryParse('${b['preferred_pickup_at'] ?? ''}');

  /// Which group a pickup belongs to, by Philippine calendar day.
  static String _bucket(DateTime? at) {
    if (at == null) return 'No time set';
    if (at.isBefore(DateTime.now().toUtc())) return 'Overdue';
    final ph = at.toUtc().add(const Duration(hours: 8));
    final now = PickupRules.phNow();
    final days = DateTime(
      ph.year,
      ph.month,
      ph.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Tomorrow';
    if (days <= 7) return 'This week';
    return 'Later';
  }

  /// Group for a donation: by its preferred time (older entries) or by the
  /// next of the donor's pickup days.
  static String _bucketOf(Map b) {
    final at = _when(b);
    if (at != null) return _bucket(at);
    final days = pickupDaysOf(b['pickup_days']);
    if (days.isEmpty) return 'No time set';
    final today = PickupRules.phNow().weekday;
    if (days.contains(today)) return 'Today';
    if (days.contains(today % 7 + 1)) return 'Tomorrow';
    return 'This week';
  }

  /// "in 2 h", "in 3 days", "45 min late", "2 days late".
  static String _relative(DateTime at) {
    final diff = at.difference(DateTime.now().toUtc());
    final late = diff.isNegative;
    final d = diff.abs();
    final text = d.inDays >= 1
        ? '${d.inDays} day${d.inDays == 1 ? '' : 's'}'
        : d.inHours >= 1
        ? '${d.inHours} h'
        : '${math.max(1, d.inMinutes)} min';
    return late ? '$text late' : 'in $text';
  }

  bool _matches(Map b) {
    if (_search.isEmpty) return true;
    final hay = [
      b['batch_reference'],
      b['donor'],
      b['donor_contact'],
      b['pickup_address'],
      b['report_label'],
    ].join(' ').toLowerCase();
    return hay.contains(_search.toLowerCase());
  }

  Future<void> _open(Map b) async {
    await openDonationByQr(context, '${b['batch_reference']}');
    if (mounted) _reload(); // goods may have been received in the sheet
  }

  @override
  Widget build(BuildContext context) {
    final side = math.max(
      Space.md,
      (MediaQuery.sizeOf(context).width - Breakpoints.contentMax) / 2,
    );
    return FutureBuilder<ApiResult>(
      future: _load,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return ListView(
            padding: EdgeInsets.fromLTRB(side, Space.md, side, Space.lg),
            children: const [SkeletonCard(), Gaps.v12, SkeletonCard()],
          );
        }
        final r = snap.data;
        if (r == null || !r.ok || r.json is! List) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: ErrorView.forStatus(
                r?.status ?? 0,
                r?.errorText ?? '',
                onRetry: _reload,
              ),
            ),
          );
        }

        final all = (r.json as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final grouped = <String, List<Map<String, dynamic>>>{
          for (final g in _groups) g: [],
        };
        for (final b in all) {
          grouped[_bucketOf(b)]!.add(b);
        }
        final shownGroups = _group == null ? _groups : [_group!];

        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: Scrollbar(
            controller: _scroll,
            thumbVisibility: true,
            child: ListView(
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(side, Space.md, side, Space.xl),
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: PageHeader(
                        'Door to Door pickups',
                        subtitle:
                            'Donations waiting to be collected, soonest first.',
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Show on map',
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const PickupMapScreen(
                              standalone: true,
                            ),
                          ),
                        );
                        if (mounted) _reload();
                      },
                      icon: const Icon(Icons.map_outlined),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const _PickupGuide(),
                Gaps.v12,
                TextField(
                  controller: _searchC,
                  onChanged: (v) => setState(() => _search = v.trim()),
                  decoration: InputDecoration(
                    hintText: 'Search donor, address, reference or report',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(() {
                              _searchC.clear();
                              _search = '';
                            }),
                          ),
                  ),
                ),
                Gaps.v12,
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: Space.xs),
                        child: ChoiceChip(
                          label: Text('All (${all.length})'),
                          selected: _group == null,
                          onSelected: (_) => setState(() => _group = null),
                        ),
                      ),
                      for (final g in _groups)
                        if (grouped[g]!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: Space.xs),
                            child: ChoiceChip(
                              avatar: g == 'Overdue'
                                  ? Icon(
                                      Icons.warning_amber_rounded,
                                      size: 18,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    )
                                  : null,
                              label: Text('$g (${grouped[g]!.length})'),
                              selected: _group == g,
                              onSelected: (_) => setState(
                                () => _group = _group == g ? null : g,
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
                if (all.isEmpty) ...[
                  Gaps.v24,
                  AppCard(
                    child: EmptyView(
                      compact: true,
                      icon: Icons.local_shipping_outlined,
                      title: 'No pickups waiting',
                      message:
                          'When a donor chooses Door to Door, the pickup shows up '
                          'here with their address, pickup days and number.',
                    ),
                  ),
                ],
                for (final g in shownGroups)
                  if (grouped[g]!.where(_matches).isNotEmpty) ...[
                    SectionHeader('$g · ${grouped[g]!.where(_matches).length}'),
                    for (final b in grouped[g]!.where(_matches))
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.sm),
                        child: _PickupCard(
                          b: b,
                          when: _when(b),
                          overdue: g == 'Overdue',
                          relative: _when(b) == null
                              ? null
                              : _relative(_when(b)!),
                          onOpen: () => _open(b),
                        ),
                      ),
                  ],
                if (all.isNotEmpty &&
                    shownGroups.every(
                      (g) => grouped[g]!.where(_matches).isEmpty,
                    )) ...[
                  Gaps.v24,
                  AppCard(
                    child: EmptyView(
                      compact: true,
                      icon: Icons.search_off,
                      title: 'No pickups match',
                      message: 'Try another search or choose All.',
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One pickup: when, who, how to reach them, where, and what to collect.
class _PickupCard extends StatelessWidget {
  final Map<String, dynamic> b;
  final DateTime? when;
  final bool overdue;
  final String? relative;
  final VoidCallback onOpen;
  const _PickupCard({
    required this.b,
    required this.when,
    required this.overdue,
    required this.relative,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final phone = '${b['donor_contact'] ?? ''}'.trim();
    final address = '${b['pickup_address'] ?? ''}'.trim();
    final notes = '${b['pickup_notes'] ?? ''}'.trim();
    final lat = (b['pickup_lat'] as num?)?.toDouble();
    final lng = (b['pickup_lng'] as num?)?.toDouble();
    final summary = (b['items_summary'] as List? ?? const [])
        .map((e) => '$e')
        .toList();
    final partly = b['status'] == 'Partly Received';
    final timeColor = overdue ? cs.error : cs.primary;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // When
          Row(
            children: [
              Icon(
                overdue ? Icons.warning_amber_rounded : Icons.event_outlined,
                color: timeColor,
              ),
              Gaps.h8,
              Expanded(
                child: Text(
                  when != null
                      ? formatPickupTime(when!)
                      : b['pickup_days_label'] != null
                      ? 'Home on ${b['pickup_days_label']}'
                          '${b['pickup_hours'] != null ? ' · ${b['pickup_hours']}' : ''}'
                      : 'No preferred time',
                  style: t.titleMedium?.copyWith(color: timeColor),
                ),
              ),
              if (relative != null)
                Text(
                  relative!,
                  style: t.labelLarge?.copyWith(color: timeColor),
                ),
            ],
          ),
          if (partly) ...[Gaps.v8, const StatusChip('Partly Received')],
          // Close to the automatic expiry: say so on the card.
          if ((b['days_left'] as num?) != null && (b['days_left'] as num) <= 3) ...[
            Gaps.v8,
            ExpiryNote(b, forStaff: true),
          ],
          const Divider(height: Space.lg),

          // Who
          Row(
            children: [
              Icon(Icons.person_outline, color: cs.onSurfaceVariant),
              Gaps.h8,
              Expanded(child: Text('${b['donor']}', style: t.titleSmall)),
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('${b['donor_type'] ?? 'Donor'}'),
              ),
            ],
          ),
          Gaps.v8,
          if (phone.isNotEmpty)
            ContactButtons(
              phone: phone,
              smsMessage:
                  'Hi, this is CSWS Mandaue about your NexaAid donation ${b['batch_reference']}.',
            )
          else
            Text(
              'No contact number on file',
              style: t.bodyMedium?.copyWith(color: cs.error),
            ),
          Gaps.v12,

          // Where
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.home_outlined, color: cs.onSurfaceVariant),
              Gaps.h8,
              Expanded(child: Text(address, style: t.bodyLarge)),
            ],
          ),
          if (notes.isNotEmpty) ...[
            Gaps.v8,
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.sm),
              decoration: BoxDecoration(
                color: cs.tertiaryContainer.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text('Note from donor: $notes', style: t.bodyMedium),
            ),
          ],
          Gaps.v8,
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => openNavigation(
                  context,
                  lat: lat,
                  lng: lng,
                  address: address,
                ),
                icon: const Icon(Icons.directions, size: 18),
                label: const Text('Navigate'),
              ),
              OutlinedButton.icon(
                onPressed: () => copyText(context, address, 'Address'),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy address'),
              ),
            ],
          ),
          const Divider(height: Space.lg),

          // What
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, color: cs.onSurfaceVariant),
              Gaps.h8,
              Expanded(
                child: Text(
                  '${b['pending_items']} of ${b['total_items']} item(s) to collect',
                  style: t.titleSmall,
                ),
              ),
            ],
          ),
          Gaps.v4,
          for (final s in summary.take(3))
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text('• $s', style: t.bodyMedium),
            ),
          if (summary.length > 3)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text(
                'and ${summary.length - 3} more',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          Gaps.v8,
          Text(
            'For ${b['report_label'] ?? 'report'} · ${b['batch_reference']}',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v12,
          AppButton(
            'Open to receive goods',
            icon: Icons.qr_code_scanner,
            expand: true,
            onPressed: onOpen,
          ),
        ],
      ),
    );
  }
}

/// Short how-to for CSWS staff, collapsed by default.
class _PickupGuide extends StatelessWidget {
  const _PickupGuide();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const steps = [
      'Call or text the donor a day before to confirm the time and that the goods are ready.',
      'Go in pairs, during pickup hours. Stay at the gate; do not enter homes.',
      'Tap Navigate to open directions. Call the donor when you are near.',
      'Ask the donor to show their QR code. Tap "Open to receive goods", or scan it from the Receive tab.',
      'Count what you actually collect and record that quantity for each item.',
      'Expired, spoiled or unsafe items: do not accept them; write the reason in the notes.',
      'Donor not home or no answer: call once more, then leave it on the board and arrange a new time.',
      'Keep donor numbers and addresses private. Use them only for this pickup.',
    ];
    return AppCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.help_outline),
          title: Text('How Door to Door pickups work', style: t.titleSmall),
          childrenPadding: const EdgeInsets.fromLTRB(
            Space.md,
            0,
            Space.md,
            Space.md,
          ),
          children: [
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      child: Text('${i + 1}.', style: t.labelLarge),
                    ),
                    Expanded(child: Text(steps[i], style: t.bodyMedium)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
