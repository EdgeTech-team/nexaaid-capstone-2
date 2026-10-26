import 'package:flutter/material.dart';

import 'home_nav.dart';
import 'input_formatters.dart' show pesos;
import 'ops_screens.dart' show CmoEntryDetails;
import 'records_screens.dart' show DonationRecordsScreen;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// CMO Representative (UC-C1 / UC-C2, City Confirmation Module).
//
// Oct 23 redesign: one clear job, "acknowledge what CSWS received".
//   Acknowledge tab  today's work only: how many need review, how many were
//                    acknowledged today, and the queue. Each card opens a
//                    review page with Cancel / Acknowledge; a success page
//                    follows. Hold and Mark for review sit in the review
//                    page's menu, and held entries have their own page.
//   History tab      every acknowledged entry, with search, filters and
//                    paging, plus the summary per report (UC-C2 / 7.4).
// Acknowledging is final (task #10) and is one action (task #11); it is
// said once on the review page, not on every card. The server refuses a
// second acknowledgement, and the button is disabled while it is sent.
// ---------------------------------------------------------------------------

const _amber = Color(0xFFB7791F);
const _green = Color(0xFF2E7D32);

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

DateTime? _time(Object? raw) {
  final d = DateTime.tryParse('${raw ?? ''}');
  return d?.toLocal();
}

String _clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} '
      '${d.hour < 12 ? 'AM' : 'PM'}';
}

/// "today, 2:40 PM", "yesterday, 9:05 AM" or "Oct 21, 2026, 10:23 AM".
String _when(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return 'today, ${_clock(d)}';
  if (day == today.subtract(const Duration(days: 1))) {
    return 'yesterday, ${_clock(d)}';
  }
  return '${_months[d.month - 1]} ${d.day}, ${d.year}, ${_clock(d)}';
}

List<Map> _items(Map e) => ((e['items'] as List?) ?? const []).cast<Map>();

/// "20 containers Drinking water"
String _itemLine(Map i) =>
    '${i['quantity']} ${i['unit'] ?? ''} ${i['item_name'] ?? 'Item'}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

/// "Earthquake · Centro · Drop Off"
String _where(Map e) => [
  e['disaster_type'],
  e['barangay'],
  e['handover_method'],
].where((x) => x != null && '$x'.isNotEmpty).join(' · ');

String _ref(Map e) => '${e['batch_reference']}';

/// Widest the review page grows on a laptop; phones use their full width.
const _maxWidth = 640.0;

/// "Flood · Subangdaku": the report without its number ("#40 ...").
String _reportName(Map e) {
  final parts = [
    e['disaster_type'],
    e['barangay'],
  ].where((x) => x != null && '$x'.isNotEmpty).join(' · ');
  if (parts.isNotEmpty) return parts;
  final label = '${e['report_label'] ?? ''}'
      .replaceFirst(RegExp(r'^#\d+\s*'), '')
      .replaceAll(' - ', ' · ')
      .trim();
  return label.isEmpty ? 'Disaster report' : label;
}

/// "20 cans", or "100 sets · Pack of 10 x 1 sets". The packaging is left
/// out when it only repeats the amount ("1 cans").
String _amount(Map i) {
  final unit = '${i['unit'] ?? ''}'.trim();
  final base = '${i['quantity']} $unit'.trim();
  final pack = '${i['packaging'] ?? ''}'.trim();
  final repeats = RegExp('^\\d+(\\.\\d+)?\\s*${RegExp.escape(unit)}\$');
  if (pack.isEmpty || (unit.isNotEmpty && repeats.hasMatch(pack))) {
    return base;
  }
  return '$base · $pack';
}

/// Waiting status in words the CMO uses.
(String, String) _chip(Map e) {
  if (e['acknowledged'] == true) return ('Acknowledged', 'Acknowledged');
  return switch (e['cmo_decision']) {
    'On Hold' => ('On Hold', 'On hold'),
    'Pending Review' => ('Pending Review', 'Marked for review'),
    _ => ('Pending Review', 'Needs review'),
  };
}

/// Text that matches the search box: reference, items, donor, place.
bool _matches(Map e, String q) {
  final s = q.trim().toLowerCase();
  if (s.isEmpty) return true;
  return [
    _ref(e),
    e['donor'],
    e['barangay'],
    e['disaster_type'],
    e['report_label'],
    for (final i in _items(e)) i['item_name'],
  ].join(' ').toLowerCase().contains(s);
}

int _byTime(Map a, Map b, String key, bool newest) {
  final ta = _time(a[key]) ?? DateTime(0);
  final tb = _time(b[key]) ?? DateTime(0);
  return newest ? tb.compareTo(ta) : ta.compareTo(tb);
}

// ----- shared pieces -----------------------------------------------------------

/// Round icon on a soft tint, used for card leads and section icons.
class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;
  const _Badge(this.icon, this.color, {this.size = 44});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      shape: BoxShape.circle,
    ),
    child: Icon(icon, color: color, size: size * 0.5),
  );
}

/// One donation entry in a list: reference, status, place, items, when,
/// donor, and (in the queue) one clear action button.
class CmoEntryCard extends StatelessWidget {
  final Map entry;
  final String? actionLabel;
  final VoidCallback? onTap;

  /// History cards show when it was acknowledged instead of received.
  final bool history;

  const CmoEntryCard(
    this.entry, {
    super.key,
    this.actionLabel,
    this.onTap,
    this.history = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final e = entry;
    final items = _items(e);
    final (status, label) = _chip(e);
    final at = _time(history ? e['acknowledged_at'] : e['received_at']);
    final reason = e['hold_reason'] as String?;
    return AppCard(
      margin: const EdgeInsets.only(bottom: Space.sm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Badge(Icons.qr_code_2, cs.primary, size: 40),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _ref(e),
                      style: t.titleSmall?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_where(e).isNotEmpty)
                      Text(
                        _where(e),
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Gaps.h8,
              StatusChip(status, label: label),
            ],
          ),
          Gaps.v12,
          _Line(
            Icons.inventory_2_outlined,
            items.isEmpty
                ? 'No items'
                : '${_itemLine(items.first)}'
                      '${items.length > 1 ? '  +${items.length - 1} more' : ''}',
          ),
          if (at != null)
            _Line(
              Icons.event_outlined,
              '${history ? 'Acknowledged' : 'Received'} ${_when(at)}',
            ),
          if (!history)
            _Line(Icons.person_outline, 'Donor: ${e['donor'] ?? 'Donor'}'),
          if (reason != null && e['acknowledged'] != true)
            _Line(Icons.info_outline, 'Reason: $reason', strong: true),
          if (actionLabel != null) ...[
            Gaps.v12,
            FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      actionLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Gaps.h8,
                  const Icon(Icons.arrow_forward, size: 18),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool strong;
  const _Line(this.icon, this.text, {this.strong = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          Gaps.h8,
          Expanded(
            child: Text(
              text,
              style: t.bodyMedium?.copyWith(
                fontWeight: strong ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A large tappable row: icon, title, one line of help, arrow.
class _NavTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _NavTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      margin: const EdgeInsets.only(bottom: Space.sm),
      onTap: onTap,
      child: Row(
        children: [
          _Badge(icon, color),
          Gaps.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                Gaps.v4,
                Text(
                  subtitle,
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// Search box with a sort menu, used by the queue, On hold and History.
class _SearchSort extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onSearch;
  final bool newest;
  final ValueChanged<bool> onSort;
  const _SearchSort({
    required this.hint,
    required this.onSearch,
    required this.newest,
    required this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            onChanged: onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              prefixIcon: const Icon(Icons.search),
            ),
          ),
        ),
        Gaps.h8,
        PopupMenuButton<bool>(
          tooltip: 'Sort',
          initialValue: newest,
          onSelected: onSort,
          itemBuilder: (_) => const [
            PopupMenuItem(value: true, child: Text('Newest first')),
            PopupMenuItem(value: false, child: Text('Oldest first')),
          ],
          child: Chip(
            avatar: const Icon(Icons.sort, size: 18),
            label: Text(newest ? 'Newest' : 'Oldest'),
          ),
        ),
      ],
    );
  }
}

// ----- Acknowledge tab ---------------------------------------------------------

class CmoScreen extends StatefulWidget {
  const CmoScreen({super.key});

  @override
  State<CmoScreen> createState() => _CmoScreenState();
}

class _CmoScreenState extends State<CmoScreen>
    with HomeTargetListener<CmoScreen> {
  int _loads = 0;
  String _query = '';
  bool _newest = true;
  final _queueKey = GlobalKey();

  @override
  String get homeTab => 'Acknowledge';

  @override
  void applyHomeTarget(HomeTarget target) {
    _loads++; // e.g. an entry was just acknowledged from a notification
  }

  void _reload() {
    if (mounted) setState(() => _loads++);
  }

  void _scrollToQueue() {
    final c = _queueKey.currentContext;
    if (c != null) {
      Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300));
    }
  }

  Future<void> _open(Map e) async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => CmoReviewScreen(entry: e)));
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Loader(
      key: ValueKey(_loads),
      load: [
        () => api.get('/cmo/dashboard'),
        () => api.get('/cmo/entries/pending'),
      ],
      builder: (context, data) {
        final dash = data[0] as Map;
        final pending = (data[1] as List).cast<Map>();
        final held = pending.where((e) => e['cmo_decision'] == 'On Hold');
        final queue =
            pending
                .where((e) => e['cmo_decision'] != 'On Hold')
                .where((e) => _matches(e, _query))
                .toList()
              ..sort((a, b) => _byTime(a, b, 'received_at', _newest));
        final waiting =
            dash['needs_review_entries'] ??
            pending.where((e) => e['cmo_decision'] != 'On Hold').length;
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            Space.md,
            Space.md,
            Space.xl,
          ),
          children: [
            const PageHeader(
              'Acknowledge Donations',
              subtitle: 'Review donations received by CSWS.',
            ),
            StatGrid([
              StatTile(
                'Needs review',
                '$waiting',
                Icons.pending_actions_outlined,
                color: _amber,
                note: 'Awaiting acknowledgement',
                onTap: _scrollToQueue,
              ),
              StatTile(
                'Acknowledged today',
                '${dash['acknowledged_today_entries'] ?? 0}',
                Icons.task_alt,
                color: _green,
                note: 'Completed today',
              ),
            ]),
            Gaps.v12,
            _NavTile(
              icon: Icons.history,
              color: cs.primary,
              title: 'History',
              subtitle:
                  'Search all acknowledged donations and view past records.',
              onTap: () => HomeNav.go(context, const HomeTarget('History')),
            ),
            _NavTile(
              icon: Icons.pause_circle_outline,
              color: _amber,
              title: 'On hold',
              subtitle: held.isEmpty
                  ? 'No donations on hold.'
                  : '${held.length} donation${held.length == 1 ? '' : 's'} '
                        'waiting for more information.',
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CmoOnHoldScreen()),
                );
                _reload();
              },
            ),
            Gaps.v8,
            Row(
              key: _queueKey,
              children: [
                Expanded(child: Text('Needs review', style: t.titleMedium)),
                Text(
                  '${queue.length} result${queue.length == 1 ? '' : 's'}',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
            Gaps.v8,
            _SearchSort(
              hint: 'Search by donation ID, item or donor',
              onSearch: (v) => setState(() => _query = v),
              newest: _newest,
              onSort: (v) => setState(() => _newest = v),
            ),
            Gaps.v12,
            if (queue.isEmpty)
              EmptyView(
                icon: Icons.task_alt,
                title: _query.isEmpty
                    ? 'All caught up'
                    : 'No donation matches "$_query"',
                message: _query.isEmpty
                    ? 'New donations appear here once CSWS receives them.'
                    : null,
                compact: true,
              ),
            for (final e in queue)
              CmoEntryCard(
                e,
                actionLabel: 'Review & Acknowledge',
                onTap: () => _open(e),
              ),
          ],
        );
      },
    );
  }
}

// ----- review page ---------------------------------------------------------------

/// UC-C1 steps 2 to 5: the CMO checks one entry and acknowledges it.
/// Cancel goes back; Hold / Mark for review are in the menu.
class CmoReviewScreen extends StatefulWidget {
  final Map entry;
  const CmoReviewScreen({super.key, required this.entry});

  @override
  State<CmoReviewScreen> createState() => _CmoReviewScreenState();
}

class _CmoReviewScreenState extends State<CmoReviewScreen> {
  bool _busy = false;

  Map get e => widget.entry;

  String get _path => '/cmo/entries/${Uri.encodeComponent(_ref(e))}/decide';

  Future<void> _acknowledge() async {
    if (_busy) return; // never sent twice
    setState(() => _busy = true);
    final r = await api.post(
      _path,
      body: {'status': 'Acknowledged', 'notes': null},
    );
    if (!mounted) return;
    if (r.ok) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => CmoAcknowledgedScreen(entry: e)),
        result: true,
      );
      return;
    }
    setState(() => _busy = false);
    AppToast.info(
      context,
      r.status == 0 ? 'Cannot reach the server' : r.errorText,
    );
  }

  Future<void> _decide(String decision) async {
    final v = await formDialog(
      context,
      title: decision == 'On Hold' ? 'Put on hold' : 'Mark for review',
      message: decision == 'On Hold'
          ? 'Say what is missing. The donor and CSWS Main Office see it.'
          : 'Say what you still need to check.',
      fields: const [DialogField('notes', 'Reason', multiline: true)],
    );
    if (v == null || !mounted) return;
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.post(_path, body: {'status': decision, 'notes': v['notes']}),
      success: decision == 'On Hold'
          ? '${_ref(e)} is on hold'
          : '${_ref(e)} marked for review',
    );
    if (!mounted) return;
    if (r.ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final (status, label) = _chip(e);
    final received = _time(e['received_at']);
    final value = (e['estimated_value'] as num?) ?? 0;
    final reason = (e['hold_reason'] ?? '').toString().trim();
    final held = e['cmo_decision'] == 'On Hold';
    final items = _items(e);
    return Scaffold(
      appBar: AppBar(title: const Text('Review donation')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: ListView(
            padding: const EdgeInsets.all(Space.md),
            children: [
              AppCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Badge(Icons.qr_code_2, cs.primary, size: 52),
                    Gaps.h12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _ref(e),
                            style: t.titleMedium?.copyWith(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (_where(e).isNotEmpty)
                            Text(
                              _where(e),
                              style: t.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          if (received != null)
                            Text(
                              'Received ${_when(received)}',
                              style: t.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          Gaps.v8,
                          StatusChip(status, label: label),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Why it was held / marked for review earlier (the CMO's own
              // reason; donors' notes are not shown here).
              if (reason.isNotEmpty) ...[
                Gaps.v12,
                Container(
                  padding: const EdgeInsets.all(Space.sm),
                  decoration: BoxDecoration(
                    color: _amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, color: _amber, size: 20),
                      Gaps.h8,
                      Expanded(
                        child: Text(
                          '${held ? 'On hold' : 'Marked for review'}: $reason',
                          style: t.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              Gaps.v12,
              AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.xs,
                ),
                child: Column(
                  children: [
                    _InfoRow(
                      icon: Icons.person_outline,
                      label: 'Donor',
                      value: '${e['donor'] ?? 'Donor'}',
                    ),
                    const Divider(height: 1),
                    _InfoRow(
                      icon: Icons.flood_outlined,
                      label: 'Disaster report',
                      value: _reportName(e),
                    ),
                  ],
                ),
              ),
              Gaps.v16,
              Text(
                'Items (${items.length})',
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Gaps.v8,
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var n = 0; n < items.length; n++) ...[
                      if (n > 0) const Divider(height: 1, indent: 64),
                      ListTile(
                        leading: _Badge(
                          Icons.inventory_2_outlined,
                          cs.primary,
                          size: 40,
                        ),
                        title: Text(
                          '${items[n]['item_name'] ?? 'Item'}',
                          style: t.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(_amount(items[n])),
                      ),
                    ],
                    if (value > 0) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.all(Space.md),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Estimated value',
                                style: t.bodyMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Text(
                              pesos(value) ?? '',
                              style: t.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      // Same width as the content, so the buttons never stretch across a
      // laptop screen. Acknowledge is the main action; Hold and Mark for
      // review sit under it (UC-C1 alt 4a / 4b), each asking for a reason.
      bottomNavigationBar: Material(
        elevation: 8,
        color: cs.surface,
        child: SafeArea(
          child: Align(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _maxWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.md,
                  Space.sm,
                  Space.md,
                  Space.md,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _acknowledge,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      icon: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: const Text('Acknowledge'),
                    ),
                    Gaps.v8,
                    Row(
                      children: [
                        if (!held) ...[
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _decide('On Hold'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                              ),
                              icon: const Icon(Icons.pause_circle_outline),
                              label: const Text('Hold'),
                            ),
                          ),
                          Gaps.h8,
                        ],
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _decide('Pending Review'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                            icon: const Icon(Icons.rate_review_outlined),
                            label: const Text(
                              'Mark for review',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Gaps.v8,
                    Text(
                      'Acknowledging is final. Not sure yet? Hold it or '
                      'mark it for review.',
                      textAlign: TextAlign.center,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One labelled line in the details card: icon, small label, value.
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        children: [
          Icon(icon, color: cs.onSurfaceVariant),
          Gaps.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                Text(value, style: t.bodyLarge),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----- success page ----------------------------------------------------------------

/// Shown once after acknowledging. The entry has left the queue.
class CmoAcknowledgedScreen extends StatelessWidget {
  final Map entry;
  const CmoAcknowledgedScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final items = _items(entry);
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(Space.lg),
            children: [
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                    color: _green,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 56),
                ),
              ),
              Gaps.v24,
              Semantics(
                liveRegion: true,
                child: Text(
                  'Donation acknowledged',
                  textAlign: TextAlign.center,
                  style: t.headlineSmall,
                ),
              ),
              Gaps.v8,
              Text(
                'Main Office can now put it on a delivery. You can find it '
                'in History.',
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v24,
              AppCard(
                child: Row(
                  children: [
                    _Badge(Icons.qr_code_2, cs.primary),
                    Gaps.h12,
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _ref(entry),
                            style: t.titleSmall?.copyWith(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (_where(entry).isNotEmpty)
                            Text(
                              _where(entry),
                              style: t.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          if (items.isNotEmpty)
                            Text(
                              '${_itemLine(items.first)}'
                              '${items.length > 1 ? '  +${items.length - 1} more' : ''}',
                              style: t.bodyMedium,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Gaps.v24,
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text('Back to list'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----- On hold page ----------------------------------------------------------------

/// Entries the CMO paused, with the reason. Opening one goes back to the
/// review page, where it can be acknowledged once the issue is resolved.
class CmoOnHoldScreen extends StatefulWidget {
  const CmoOnHoldScreen({super.key});

  @override
  State<CmoOnHoldScreen> createState() => _CmoOnHoldScreenState();
}

class _CmoOnHoldScreenState extends State<CmoOnHoldScreen> {
  int _loads = 0;
  String _query = '';
  bool _newest = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('On hold')),
      body: Loader(
        key: ValueKey(_loads),
        load: [() => api.get('/cmo/entries/pending')],
        builder: (context, data) {
          final held =
              (data[0] as List)
                  .cast<Map>()
                  .where((e) => e['cmo_decision'] == 'On Hold')
                  .where((e) => _matches(e, _query))
                  .toList()
                ..sort((a, b) => _byTime(a, b, 'received_at', _newest));
          return ListView(
            padding: const EdgeInsets.all(Space.md),
            children: [
              Text(
                'Donations that need more information before you '
                'acknowledge them.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v12,
              _SearchSort(
                hint: 'Search by donation ID, item or donor',
                onSearch: (v) => setState(() => _query = v),
                newest: _newest,
                onSort: (v) => setState(() => _newest = v),
              ),
              Gaps.v12,
              if (held.isEmpty)
                const EmptyView(
                  icon: Icons.pause_circle_outline,
                  title: 'Nothing on hold',
                  compact: true,
                ),
              for (final e in held)
                CmoEntryCard(
                  e,
                  actionLabel: 'Review',
                  onTap: () async {
                    final changed = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => CmoReviewScreen(entry: e),
                      ),
                    );
                    if (changed == true && mounted) setState(() => _loads++);
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

// ----- History tab -----------------------------------------------------------------

/// Every acknowledged entry (search, disaster and barangay filters, newest
/// or oldest first, 20 at a time), and the summary per report (UC-C2).
class CmoHistoryScreen extends StatefulWidget {
  const CmoHistoryScreen({super.key});

  @override
  State<CmoHistoryScreen> createState() => _CmoHistoryScreenState();
}

class _CmoHistoryScreenState extends State<CmoHistoryScreen>
    with HomeTargetListener<CmoHistoryScreen> {
  static const _page = 20;
  int _loads = 0;
  String _view = 'donations';
  String _query = '';
  bool _newest = true;
  String? _disaster;
  String? _barangay;
  int _shown = _page;

  @override
  String get homeTab => 'History';

  @override
  void applyHomeTarget(HomeTarget target) => _loads++;

  void _reset() => _shown = _page;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Loader(
      key: ValueKey(_loads),
      load: [
        () => api.get('/cmo/entries/acknowledged'),
        () => api.get('/cmo/dashboard'),
      ],
      builder: (context, data) {
        final all = (data[0] as List).cast<Map>();
        final perReport = ((data[1] as Map)['per_report'] as List? ?? const [])
            .cast<Map>();
        final disasters = {
          for (final e in all)
            if (e['disaster_type'] != null) '${e['disaster_type']}',
        }.toList()..sort();
        final barangays = {
          for (final e in all)
            if (e['barangay'] != null) '${e['barangay']}',
        }.toList()..sort();
        final rows =
            all
                .where(
                  (e) => _disaster == null || e['disaster_type'] == _disaster,
                )
                .where((e) => _barangay == null || e['barangay'] == _barangay)
                .where((e) => _matches(e, _query))
                .toList()
              ..sort((a, b) => _byTime(a, b, 'acknowledged_at', _newest));
        final page = rows.take(_shown).toList();
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            Space.md,
            Space.md,
            Space.xl,
          ),
          children: [
            PageHeader('History', subtitle: 'Every donation you acknowledged.'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'donations',
                  icon: Icon(Icons.list_alt),
                  label: Text('Donations'),
                ),
                ButtonSegment(
                  value: 'reports',
                  icon: Icon(Icons.summarize_outlined),
                  label: Text('Per report'),
                ),
              ],
              selected: {_view},
              onSelectionChanged: (s) => setState(() => _view = s.first),
            ),
            Gaps.v12,
            if (_view == 'donations') ...[
              _SearchSort(
                hint: 'Search by donation ID, item or donor',
                onSearch: (v) => setState(() {
                  _query = v;
                  _reset();
                }),
                newest: _newest,
                onSort: (v) => setState(() => _newest = v),
              ),
              Gaps.v8,
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  _FilterMenu(
                    label: 'All disasters',
                    value: _disaster,
                    options: disasters,
                    onChanged: (v) => setState(() {
                      _disaster = v;
                      _reset();
                    }),
                  ),
                  _FilterMenu(
                    label: 'All barangays',
                    value: _barangay,
                    options: barangays,
                    onChanged: (v) => setState(() {
                      _barangay = v;
                      _reset();
                    }),
                  ),
                ],
              ),
              Gaps.v8,
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Showing ${page.length} of ${rows.length}',
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Donation records')),
                          body: const DonationRecordsScreen(header: false),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('All records'),
                  ),
                ],
              ),
              Gaps.v8,
              if (rows.isEmpty)
                EmptyView(
                  icon: Icons.history,
                  title: all.isEmpty
                      ? 'No acknowledged donations yet'
                      : 'No donation matches these filters',
                  compact: true,
                ),
              for (final e in page)
                CmoEntryCard(
                  e,
                  history: true,
                  onTap: () => showDetailPopout<void>(
                    context,
                    title: 'Donation entry',
                    child: CmoEntryDetails(e),
                  ),
                ),
              if (rows.length > page.length)
                OutlinedButton(
                  onPressed: () => setState(() => _shown += _page),
                  child: Text('Show ${rows.length - page.length} more'),
                ),
            ] else ...[
              if (perReport.isEmpty)
                const EmptyView(
                  icon: Icons.summarize_outlined,
                  title: 'No donations yet',
                  compact: true,
                ),
              for (final r in perReport)
                AppCard(
                  margin: const EdgeInsets.only(bottom: Space.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r['report_label']}', style: t.titleSmall),
                      Gaps.v4,
                      Text(
                        '${r['confirmed_count']} item(s) acknowledged '
                        '(${r['confirmed_quantity']} units'
                        '${(r['confirmed_value'] as num? ?? 0) > 0 ? ', ${pesos(r['confirmed_value'] as num)}' : ''}'
                        ') · ${r['pending_count']} waiting',
                        style: t.bodyMedium,
                      ),
                      Gaps.v8,
                      Progress(
                        delivered: 0,
                        needed: 0,
                        percent: r['fulfillment_percentage'] as num? ?? 0,
                      ),
                    ],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// "All barangays ▾" chip that opens the choices; null = all.
class _FilterMenu extends StatelessWidget {
  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  const _FilterMenu({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: (v) => onChanged(v.isEmpty ? null : v),
      itemBuilder: (_) => [
        PopupMenuItem(value: '', child: Text(label)),
        for (final o in options) PopupMenuItem(value: o, child: Text(o)),
      ],
      child: Chip(
        label: Text(value ?? label),
        deleteIcon: const Icon(Icons.arrow_drop_down),
        onDeleted: () {}, // shows the arrow; the menu opens on tap
      ),
    );
  }
}
