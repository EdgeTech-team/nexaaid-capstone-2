import 'dart:async';

import 'package:flutter/material.dart';

import '../app_routes.dart';
import 'home_nav.dart';
import 'input_formatters.dart' show pesos;
import 'ops_screens.dart' show CmoEntryDetails;
import 'paged_donation_entries.dart' show searchDebounce;
import 'paginated_list.dart';
import 'records_screens.dart' show DonationRecordsScreen;
import 'widgets.dart';
import 'item_amounts.dart';

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

// UI redesign: the status tints of the design system (amber = waiting,
// green = done) instead of fixed colors, so dark mode works too.
const _amber = AppTints.amber;
const _green = AppTints.green;

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
  // G-002 (D8): "10 packs x 5 kg · Sack · Declared 50 kg · Counted 48 kg".
  if (i['amount_text'] != null) {
    return '${itemAmount(i)} · ${itemQuantities(i)}';
  }
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
// ----- shared pieces -----------------------------------------------------------

/// Icon on a soft tinted square (UI redesign [TintIcon]), used for card
/// leads and section icons.
class _Badge extends StatelessWidget {
  final IconData icon;
  final Tint tint;
  final double size;
  const _Badge(this.icon, this.tint, {this.size = 44});

  @override
  Widget build(BuildContext context) => TintIcon(icon, tint: tint, size: size);
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
              const _Badge(Icons.qr_code_2, AppTints.teal, size: 40),
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
  final Tint color;
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

/// NF-003: one CMO list (queue, On hold, History) a page at a time from
/// [path]. Search (it waits until typing stops), sort and [filters] are
/// sent to the server; a change starts again from page 1.
class _CmoList {
  _CmoList(this.path, this.filters) {
    controller = PagedController(fetch: _fetch());
  }

  final String path;
  final Map<String, String> Function() filters;
  late final PagedController controller;
  String query = '';
  bool newest = true;
  Timer? _typing;

  PageFetch _fetch() {
    final params = {
      ...filters(),
      if (query.trim().isNotEmpty) 'q': query.trim(),
      'newest': '$newest',
    };
    return (offset, limit) => api.get(
      path,
      query: {...params, 'limit': '$limit', 'offset': '$offset'},
    );
  }

  void reload() => controller.refresh(fetch: _fetch());

  void search(String v) {
    _typing?.cancel();
    _typing = Timer(searchDebounce, () {
      if (v == query) return;
      query = v;
      reload();
    });
  }

  void sort(bool v) {
    if (v == newest) return;
    newest = v;
    reload();
  }

  void dispose() {
    _typing?.cancel();
    controller.dispose();
  }
}

/// "12 results" under a list header, kept up to date as pages arrive.
Widget _resultCount(PagedController c, String Function(int n) text) =>
    ListenableBuilder(
      listenable: c,
      builder: (context, _) => Text(
        text(c.total ?? c.items.length),
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );

// ----- Acknowledge tab ---------------------------------------------------------

class CmoScreen extends StatefulWidget {
  const CmoScreen({super.key});

  @override
  State<CmoScreen> createState() => _CmoScreenState();
}

class _CmoScreenState extends State<CmoScreen>
    with HomeTargetListener<CmoScreen> {
  int _loads = 0;
  final _queueKey = GlobalKey();

  /// NF-003: the queue (everything waiting except On hold), paged.
  final _queue = _CmoList('/cmo/entries/pending', () => {'on_hold': 'false'});

  @override
  String get homeTab => 'Acknowledge';

  @override
  void applyHomeTarget(HomeTarget target) {
    _loads++; // e.g. an entry was just acknowledged from a notification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queue.reload();
    });
  }

  @override
  void dispose() {
    _queue.dispose();
    super.dispose();
  }

  void _scrollToQueue() {
    final c = _queueKey.currentContext;
    if (c != null) {
      Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 300));
    }
  }

  /// The review page stays open after a decision (UAT, Nov 14). Back here,
  /// an entry that left the queue is taken out at once; the counts and the
  /// list reload quietly in the background (Loader / PagedListView).
  Future<void> _open(Map e) async {
    final decision = await Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => CmoReviewScreen(entry: e)),
    );
    if (decision == 'Acknowledged' || decision == 'On Hold') {
      _queue.controller.removeWhere((x) => _ref(x) == _ref(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(_loads),
      load: [() => api.get('/cmo/dashboard')],
      builder: (context, data) {
        final dash = data[0] as Map;
        final waiting = (dash['needs_review_entries'] as num?)?.toInt() ?? 0;
        final held = (dash['on_hold_entries'] as num?)?.toInt() ?? 0;
        return PagedListView(
          controller: _queue.controller,
          // UI redesign: no top padding, the teal header starts at the top.
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            0,
            Space.md,
            Space.xl,
          ),
          header: [
            // UI redesign (layout only, same data and taps): the two piles
            // that wait for the CMO sit in "Needs your action" over the
            // teal header.
            HeroHeader(
              title: 'Acknowledge Donations',
              subtitle: 'Review donations received by CSWS.',
              bleed: Space.md,
              overlap: ActionCard(
                title: 'Needs your action',
                count: '${waiting + held}',
                rows: [
                  ActionRow(
                    icon: Icons.pending_actions_outlined,
                    tint: _amber,
                    label: 'Needs review',
                    count: '$waiting',
                    onTap: _scrollToQueue,
                  ),
                  ActionRow(
                    icon: Icons.pause_circle_outline,
                    tint: _amber,
                    label: 'On hold',
                    note: held == 0
                        ? 'No donations on hold.'
                        : '$held donation${held == 1 ? '' : 's'} '
                              'waiting for more information.',
                    count: '$held',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CmoOnHoldScreen(),
                      ),
                    ),
                  ),
                  // What is already done today: no arrow, nothing to open
                  // (as the old tile).
                  const Divider(height: 1),
                  ActionRow(
                    icon: Icons.task_alt,
                    tint: _green,
                    label: 'Acknowledged today',
                    count: '${dash['acknowledged_today_entries'] ?? 0}',
                  ),
                ],
              ),
            ),
            Gaps.v16,
            _NavTile(
              icon: Icons.history,
              color: AppTints.teal,
              title: 'History',
              subtitle:
                  'Search all acknowledged donations and view past records.',
              onTap: () => HomeNav.go(context, const HomeTarget('History')),
            ),
            KeyedSubtree(
              key: _queueKey,
              child: RedesignSection(
                'Needs review',
                action: _resultCount(
                  _queue.controller,
                  (n) => '$n result${n == 1 ? '' : 's'}',
                ),
              ),
            ),
            _SearchSort(
              hint: 'Search by donation ID, item or donor',
              onSearch: _queue.search,
              newest: _queue.newest,
              onSort: (v) => setState(() => _queue.sort(v)),
            ),
            Gaps.v12,
          ],
          empty: EmptyView(
            icon: Icons.task_alt,
            title: _queue.query.isEmpty
                ? 'All caught up'
                : 'No donation matches "${_queue.query}"',
            message: _queue.query.isEmpty
                ? 'New donations appear here once CSWS receives them.'
                : null,
            compact: true,
          ),
          itemBuilder: (context, e) => CmoEntryCard(
            e,
            actionLabel: 'Review & Acknowledge',
            onTap: () => _open(e),
          ),
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

  /// UAT (Nov 14): the page stays open after a decision and shows it; the
  /// list behind updates by itself. Closing (X) returns the decision.
  late final Map e = Map.of(widget.entry);
  String? _decision;

  bool get _acknowledged => _decision == 'Acknowledged';

  String get _path => '/cmo/entries/${Uri.encodeComponent(_ref(e))}/decide';

  void _close() => Navigator.of(context).pop(_decision);

  Future<void> _acknowledge() async {
    if (_busy || _acknowledged) return; // never sent twice
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.post(_path, body: {'status': 'Acknowledged', 'notes': null}),
      success: '${_ref(e)} acknowledged',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _decision = 'Acknowledged';
        e['acknowledged'] = true;
        e['cmo_decision'] = 'Acknowledged';
      }
    });
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
    setState(() {
      _busy = false;
      if (r.ok) {
        _decision = decision;
        e['cmo_decision'] = decision;
        e['hold_reason'] = v['notes'];
      }
    });
  }

  /// What was just decided, at the top of the page.
  Widget _result(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final b = Theme.of(context).brightness;
    final (tint, icon, title, text) = switch (_decision) {
      'Acknowledged' => (
        _green,
        Icons.check_circle,
        'Donation acknowledged',
        'Main Office can now put it on a delivery. You can find it in '
            'History.',
      ),
      'On Hold' => (
        _amber,
        Icons.pause_circle,
        'Put on hold',
        'The donor and CSWS Main Office see the reason. You can still '
            'acknowledge it here once it is sorted out.',
      ),
      _ => (
        _amber,
        Icons.rate_review,
        'Marked for review',
        'It stays in your queue until you acknowledge or hold it.',
      ),
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('cmo-decision'),
        margin: const EdgeInsets.only(bottom: Space.sm),
        padding: const EdgeInsets.all(Space.sm),
        decoration: BoxDecoration(
          color: tint.bgFor(b),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: tint.fgFor(b).withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tint.fgFor(b)),
            Gaps.h8,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: t.titleSmall),
                  Text(text, style: t.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
    // Back (Android, browser, the X) returns the decision to the list.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Review donation'),
          leading: _decision == null
              ? BackButton(onPressed: _close)
              : IconButton(
                  key: const ValueKey('cmo-review-close'),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: _close,
                ),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: ListView(
              padding: const EdgeInsets.all(Space.md),
              children: [
                if (_decision != null) _result(context),
                AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _Badge(Icons.qr_code_2, AppTints.teal, size: 52),
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
                      color: _amber.bgFor(Theme.of(context).brightness),
                      borderRadius: BorderRadius.circular(Radii.md),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: _amber.fgFor(Theme.of(context).brightness),
                          size: 20,
                        ),
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
                          leading: const _Badge(
                            Icons.inventory_2_outlined,
                            AppTints.teal,
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
                  child: _acknowledged
                      // Acknowledging is final: only closing is left.
                      ? FilledButton.icon(
                          onPressed: _close,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                          icon: const Icon(Icons.close),
                          label: const Text('Close'),
                        )
                      : Column(
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
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
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
                                      icon: const Icon(
                                        Icons.pause_circle_outline,
                                      ),
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
                                    icon: const Icon(
                                      Icons.rate_review_outlined,
                                    ),
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
                              style: t.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
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

// ----- On hold page ----------------------------------------------------------------

/// Entries the CMO paused, with the reason. Opening one goes back to the
/// review page, where it can be acknowledged once the issue is resolved.
class CmoOnHoldScreen extends StatefulWidget {
  const CmoOnHoldScreen({super.key});

  @override
  State<CmoOnHoldScreen> createState() => _CmoOnHoldScreenState();
}

class _CmoOnHoldScreenState extends State<CmoOnHoldScreen> {
  /// NF-003: only the entries on hold, paged and searched on the server.
  final _held = _CmoList('/cmo/entries/pending', () => {'on_hold': 'true'});

  @override
  void dispose() {
    _held.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('On hold')),
      body: PagedListView(
        controller: _held.controller,
        padding: const EdgeInsets.all(Space.md),
        header: [
          Text(
            'Donations that need more information before you '
            'acknowledge them.',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v12,
          _SearchSort(
            hint: 'Search by donation ID, item or donor',
            onSearch: _held.search,
            newest: _held.newest,
            onSort: (v) => setState(() => _held.sort(v)),
          ),
          Gaps.v12,
        ],
        empty: const EmptyView(
          icon: Icons.pause_circle_outline,
          title: 'Nothing on hold',
          compact: true,
        ),
        itemBuilder: (context, e) => CmoEntryCard(
          e,
          actionLabel: 'Review',
          onTap: () async {
            final decision = await Navigator.of(context).push<String?>(
              MaterialPageRoute(builder: (_) => CmoReviewScreen(entry: e)),
            );
            // Acknowledged or marked for review: no longer on hold.
            if (decision != null && decision != 'On Hold') {
              _held.controller.removeWhere((x) => _ref(x) == _ref(e));
            }
          },
        ),
      ),
    );
  }
}

// ----- History tab -----------------------------------------------------------------

/// Every acknowledged entry (search, disaster and barangay filters, newest
/// or oldest first, 10 at a time), and the summary per report (UC-C2).
class CmoHistoryScreen extends StatefulWidget {
  const CmoHistoryScreen({super.key});

  @override
  State<CmoHistoryScreen> createState() => _CmoHistoryScreenState();
}

class _CmoHistoryScreenState extends State<CmoHistoryScreen>
    with HomeTargetListener<CmoHistoryScreen> {
  String _view = 'donations';
  String? _disaster;
  String? _barangay;

  /// Names -> ids for the filters (GET /lookups).
  late final Future<Map<String, dynamic>> _lookups = api.lookups();
  Map<String, int> _disasterIds = const {};
  Map<String, int> _barangayIds = const {};

  /// NF-003: acknowledged entries, filtered, sorted and paged on the server.
  late final _history = _CmoList(
    '/cmo/entries/acknowledged',
    () => {
      if (_disasterIds[_disaster] != null)
        'disaster_type_id': '${_disasterIds[_disaster]}',
      if (_barangayIds[_barangay] != null)
        'barangay_id': '${_barangayIds[_barangay]}',
    },
  );

  /// UC-C2 summaries per report, a page at a time (GET /cmo/report-summaries).
  final _reports = PagedController(
    fetch: (offset, limit) => api.get(
      '/cmo/report-summaries',
      query: {'limit': '$limit', 'offset': '$offset'},
    ),
  );

  @override
  String get homeTab => 'History';

  @override
  void applyHomeTarget(HomeTarget target) {
    // NF-002: /cmo/history/per-report (a web address, Back / Forward).
    if (target.view == 'donations' || target.view == 'reports') {
      _view = target.view!;
      if (target.query != null) return; // only the sub-tab changed
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _history.reload();
      _reports.refresh();
    });
  }

  @override
  void dispose() {
    _history.dispose();
    _reports.dispose();
    super.dispose();
  }

  Map<String, int> _ids(dynamic list) => {
    for (final m in ((list as List?) ?? const []).cast<Map>())
      '${m['name']}': (m['id'] as num).toInt(),
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return FutureBuilder<Map<String, dynamic>>(
      future: _lookups,
      builder: (context, snap) {
        _disasterIds = _ids(snap.data?['disaster_types']);
        _barangayIds = _ids(snap.data?['barangays']);
        final header = <Widget>[
          // UI redesign: the teal header of every tab.
          const HeroHeader(
            title: 'History',
            subtitle: 'Every donation you acknowledged.',
            bleed: Space.md,
            bleedTop: Space.md,
          ),
          Gaps.v16,
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
            onSelectionChanged: (s) {
              setState(() => _view = s.first);
              AppRoutes.instance.viewChanged(homeTab, _view);
            },
          ),
          Gaps.v12,
          if (_view == 'donations') ...[
            _SearchSort(
              hint: 'Search by donation ID, item or donor',
              onSearch: _history.search,
              newest: _history.newest,
              onSort: (v) => setState(() => _history.sort(v)),
            ),
            Gaps.v8,
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                _FilterMenu(
                  label: 'All disasters',
                  value: _disaster,
                  options: _disasterIds.keys.toList()..sort(),
                  onChanged: (v) {
                    setState(() => _disaster = v);
                    _history.reload();
                  },
                ),
                _FilterMenu(
                  label: 'All barangays',
                  value: _barangay,
                  options: _barangayIds.keys.toList()..sort(),
                  onChanged: (v) {
                    setState(() => _barangay = v);
                    _history.reload();
                  },
                ),
              ],
            ),
            Gaps.v8,
            Row(
              children: [
                Expanded(
                  child: _resultCount(
                    _history.controller,
                    (n) => 'Showing ${_history.controller.items.length} of $n',
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
          ],
        ];
        final padding = const EdgeInsets.fromLTRB(
          Space.md,
          Space.md,
          Space.md,
          Space.xl,
        );
        if (_view == 'donations') {
          final filtered =
              _history.query.isNotEmpty ||
              _disaster != null ||
              _barangay != null;
          return PagedListView(
            key: const ValueKey('history-donations'),
            controller: _history.controller,
            padding: padding,
            header: header,
            empty: EmptyView(
              icon: Icons.history,
              title: filtered
                  ? 'No donation matches these filters'
                  : 'No acknowledged donations yet',
              compact: true,
            ),
            itemBuilder: (context, e) => CmoEntryCard(
              e,
              history: true,
              onTap: () => showDetailPopout<void>(
                context,
                title: 'Donation entry',
                child: CmoEntryDetails(e),
              ),
            ),
          );
        }
        return PagedListView(
          key: const ValueKey('history-reports'),
          controller: _reports,
          padding: padding,
          header: header,
          empty: const EmptyView(
            icon: Icons.summarize_outlined,
            title: 'No donations yet',
            compact: true,
          ),
          itemBuilder: (context, r) => AppCard(
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
