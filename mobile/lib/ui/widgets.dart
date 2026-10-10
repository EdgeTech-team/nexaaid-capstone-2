import 'package:flutter/material.dart';

import '../api.dart';
import '../design/design.dart';

// Screens that import widgets.dart also get the design system.
export '../design/design.dart';

final api = Api.instance;

// ---------------------------------------------------------------------------
// Brand colors (old names, kept so existing screens compile).
// New code: use Theme.of(context).colorScheme, or the design system in
// lib/design/. These fixed colors do not adapt to dark mode, so replace
// Brand.ink / Brand.muted with colorScheme.onSurface / onSurfaceVariant
// when you restyle your screens.
// ---------------------------------------------------------------------------
class Brand {
  static const pink = AppColors.harbor; // primary: buttons, bars, logo
  static const pinkDark = AppColors.harborDeep;
  static const pinkSoft = AppColors.harborMist; // tints and highlights
  static const ink = AppColors.ink; // headings
  static const muted = Color(0xFF6B7280); // secondary text
  static const line = Color(0xFFE0E0E0); // borders
  static const page = AppColors.paper; // page background
}

/// Pink rounded "N" square used as the NexaAid logo in the wireframes.
class NexaLogo extends StatelessWidget {
  final double size;
  const NexaLogo({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Brand.pink,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Text(
        'N',
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.5,
        ),
      ),
    );
  }
}

/// Page title + subtitle at the top of a screen.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const PageHeader(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text(title, style: t.headlineSmall)),
          if (subtitle != null) ...[
            Gaps.v4,
            Text(
              subtitle!,
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Administrator • Last updated: 10/1/2026" line under page titles.
String roleLine() {
  final d = DateTime.now();
  return '${api.role ?? 'Guest'} • Last updated: ${d.month}/${d.day}/${d.year}';
}

// ---------------------------------------------------------------------------
// Colors for statuses and priority levels: one fixed color per status,
// defined in lib/design/status.dart.
// ---------------------------------------------------------------------------
Color statusTone(String? s) => StatusColors.base(s);

Color priorityTone(String? p) => PriorityColors.base(p);

/// Old pill widget. New code: use StatusChip / PriorityChip.
class Badge2 extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final String? _status;
  final String? _priority;
  const Badge2(this.text, this.color, {super.key, this.icon})
    : _status = null,
      _priority = null;
  const Badge2._(this.text, this.color, this._status, this._priority)
    : icon = null;

  factory Badge2.status(String? s) =>
      Badge2._(s ?? '-', statusTone(s), s ?? '-', null);
  factory Badge2.priority(String? p) =>
      Badge2._(p ?? 'No priority', priorityTone(p), null, p);

  @override
  Widget build(BuildContext context) {
    if (_status != null) return StatusChip(_status);
    if (_priority != null || text == 'No priority') {
      return PriorityChip(_priority);
    }
    final tone = ToneStyle.from(
      color,
      icon ?? Icons.circle,
      Theme.of(context).brightness,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: tone.fg), Gaps.h4],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: tone.fg, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// Old name for FulfillmentBar.
class Progress extends StatelessWidget {
  final num delivered;
  final num needed;
  final num? percent;
  const Progress({
    super.key,
    required this.delivered,
    required this.needed,
    this.percent,
  });

  @override
  Widget build(BuildContext context) => FulfillmentBar(
    delivered: delivered,
    needed: needed,
    percent: percent,
    label: 'Fulfillment progress',
  );
}

/// Old name for StatCard.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  final String? note;

  /// 5.1: opens the details behind the number. Null = not clickable.
  final VoidCallback? onTap;
  const StatTile(
    this.label,
    this.value,
    this.icon, {
    super.key,
    this.color,
    this.note,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final card = StatCard(
      label: label,
      value: value,
      icon: icon,
      color: color,
      note: note ?? (onTap != null ? 'Tap to view' : null),
    );
    if (onTap == null) return card;
    // The ripple sits on top of the card so it is visible when tapped.
    return Stack(
      children: [
        card,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
}

/// Old name for StatCardGrid.
class StatGrid extends StatelessWidget {
  final List<StatTile> tiles;
  const StatGrid(this.tiles, {super.key});

  @override
  Widget build(BuildContext context) => StatCardGrid(tiles);
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Old one-line empty state. New code: use EmptyView with a title, a
/// message saying what will appear, and an action.
class EmptyState extends StatelessWidget {
  final String text;
  final IconData icon;
  const EmptyState(this.text, {super.key, this.icon = Icons.inbox_outlined});

  @override
  Widget build(BuildContext context) =>
      EmptyView(title: text, icon: icon, compact: true);
}

/// Loads data from the API and rebuilds with it. Pull down to refresh.
/// Reloads automatically when the session or data changes.
class Loader extends StatefulWidget {
  final List<Future<ApiResult> Function()> load;
  final Widget Function(BuildContext context, List<dynamic> data) builder;
  const Loader({super.key, required this.load, required this.builder});

  @override
  State<Loader> createState() => _LoaderState();
}

class _LoaderState extends State<Loader> {
  late Future<List<ApiResult>> _future = _fetch();

  Future<List<ApiResult>> _fetch() => Future.wait(widget.load.map((f) => f()));

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = _fetch();
    });
  }

  @override
  void initState() {
    super.initState();
    api.addListener(_reload); // e.g. after an action elsewhere
  }

  @override
  void dispose() {
    api.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        _reload();
        await _future;
      },
      child: FutureBuilder<List<ApiResult>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const SkeletonList();
          final bad = snap.data!.where((r) => !r.ok).toList();
          if (bad.isNotEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                ErrorView.forStatus(
                  bad.first.status,
                  bad.first.errorText,
                  onRetry: _reload,
                ),
              ],
            );
          }
          return widget.builder(
            context,
            snap.data!.map((r) => r.json).toList(),
          );
        },
      ),
    );
  }
}

/// Runs an API action, shows a green snackbar on success or the server's
/// error message on failure. Returns the result.
Future<ApiResult> act(
  BuildContext context,
  Future<ApiResult> Function() call, {
  required String success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final r = await call();
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      backgroundColor: r.ok ? AppColors.success : AppColors.danger,
      content: Text(
        r.ok
            ? success
            : r.status == 0
            ? 'Cannot reach the server'
            : r.errorText,
      ),
    ),
  );
  return r;
}

/// Small form dialog. Returns the entered values, or null if cancelled.
Future<Map<String, String>?> formDialog(
  BuildContext context, {
  required String title,
  String? message,
  required List<DialogField> fields,
  String confirm = 'Save',
}) {
  final controllers = {
    for (final f in fields) f.key: TextEditingController(text: f.initial),
  };
  final formKey = GlobalKey<FormState>();
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null) ...[
                Text(message),
                const SizedBox(height: 12),
              ],
              for (final f in fields)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: f.options != null
                      ? DropdownButtonFormField<String>(
                          initialValue: f.initial,
                          items: [
                            for (final o in f.options!)
                              DropdownMenuItem(value: o, child: Text(o)),
                          ],
                          onChanged: (v) => controllers[f.key]!.text = v ?? '',
                          decoration: InputDecoration(labelText: f.label),
                        )
                      : TextFormField(
                          controller: controllers[f.key],
                          keyboardType: f.number
                              ? TextInputType.number
                              : TextInputType.text,
                          maxLines: f.multiline ? 3 : 1,
                          decoration: InputDecoration(
                            labelText: f.label,
                            hintText: f.hint,
                          ),
                          validator: (v) {
                            final t = v?.trim() ?? '';
                            if (f.required && t.isEmpty) return 'Required';
                            if (f.number &&
                                t.isNotEmpty &&
                                int.tryParse(t) == null) {
                              return 'Enter a whole number';
                            }
                            return null;
                          },
                        ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (formKey.currentState!.validate()) {
              Navigator.pop(ctx, {
                for (final e in controllers.entries) e.key: e.value.text.trim(),
              });
            }
          },
          child: Text(confirm),
        ),
      ],
    ),
  );
}

class DialogField {
  final String key;
  final String label;
  final String initial;
  final bool number;
  final bool required;
  final bool multiline;
  final String? hint;
  final List<String>? options;
  const DialogField(
    this.key,
    this.label, {
    this.initial = '',
    this.number = false,
    this.required = true,
    this.multiline = false,
    this.hint,
    this.options,
  });
}

/// Pick a date + time, returned as an ISO string (no timezone).
Future<String?> pickDateTime(BuildContext context) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    firstDate: now.subtract(const Duration(days: 1)),
    lastDate: now.add(const Duration(days: 365)),
    initialDate: now.add(const Duration(days: 1)),
  );
  if (d == null || !context.mounted) return null;
  final t = await showTimePicker(
    context: context,
    initialTime: const TimeOfDay(hour: 8, minute: 0),
  );
  if (t == null) return null;
  return DateTime(
    d.year,
    d.month,
    d.day,
    t.hour,
    t.minute,
  ).toIso8601String().split('.').first;
}

/// "2026-10-01T08:00:00" -> "Oct 1, 2026 08:00"
String niceDate(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '-';
  const m = [
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
  final l = d.toLocal();
  final hh = l.hour.toString().padLeft(2, '0');
  final mm = l.minute.toString().padLeft(2, '0');
  return '${m[l.month - 1]} ${l.day}, ${l.year} $hh:$mm';
}

/// Id -> display name maps built from GET /lookups.
class Names {
  final Map<String, dynamic> raw;
  Names(this.raw);
  String of(String list, dynamic id, {String fallback = '?'}) {
    for (final r in (raw[list] as List? ?? const [])) {
      if ('${r['id']}' == '$id') return '${r['name']}';
    }
    return fallback;
  }

  List<Map<String, dynamic>> rows(String list) => [
    for (final r in (raw[list] as List? ?? const []))
      Map<String, dynamic>.from(r as Map),
  ];
}

/// Dropdown bound to a /lookups list, used inside forms.
class LookupDropdown extends StatelessWidget {
  final String list;
  final String label;
  final String? value;
  final bool optional;
  final ValueChanged<String?> onChanged;
  final Names names;
  const LookupDropdown({
    super.key,
    required this.list,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.names,
    this.optional = false,
  });

  @override
  Widget build(BuildContext context) {
    final rows = names.rows(list);
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      items: [
        if (optional) const DropdownMenuItem(value: '', child: Text('(none)')),
        for (final r in rows)
          DropdownMenuItem(
            value: '${r['id']}',
            child: Text('${r['name']}', overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
      validator: (v) =>
          !optional && (v == null || v.isEmpty) ? 'Please choose one' : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: rows.isEmpty
            ? _emptyHints[list] ?? 'Nothing to choose yet'
            : null,
        helperMaxLines: 2,
      ),
    );
  }
}

const _emptyHints = {
  'validated_reports': 'No validated reports yet. The Administrator must validate a report first.',
  'items': 'No items yet. Run database/seeds/demo_seed.sql in Neon.',
  'barangays': 'No barangays in the database.',
};