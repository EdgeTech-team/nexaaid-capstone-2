import 'package:flutter/material.dart';

import '../api.dart';

final api = Api.instance;

// ---------------------------------------------------------------------------
// Brand colors
// ---------------------------------------------------------------------------
class Brand {
  // Teal palette (the earlier prototype theme). The names are kept from the
  // wireframe version so every screen picks the colors up from one place.
  static const pink = Color(0xFF00695C); // primary: buttons, bars, logo
  static const pinkDark = Color(0xFF004D40);
  static const pinkSoft = Color(0xFFB2DFDB); // tints and highlights
  static const ink = Color(0xFF1F2937); // headings
  static const muted = Color(0xFF6B7280); // secondary text
  static const line = Color(0xFFE0E0E0); // borders
  static const page = Color(0xFFF5F7F6); // page background
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

/// Page title + subtitle, as at the top of every wireframe dashboard.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const PageHeader(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: Brand.ink,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: const TextStyle(color: Brand.muted)),
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
// Colors for statuses and priority levels
// ---------------------------------------------------------------------------
Color statusTone(String? s) {
  switch (s) {
    case 'Validated':
    case 'Confirmed':
    case 'Accepted':
    case 'Complete':
      return const Color(0xFF2E7D32);
    case 'Received':
    case 'In Transit':
    case 'Partial':
      return const Color(0xFF1565C0);
    case 'Delivered':
      return const Color(0xFF00838F);
    case 'Preparing':
    case 'On Hold':
    case 'Pending Review':
      return const Color(0xFFEF6C00);
    case 'Rejected':
    case 'Declined':
      return const Color(0xFFC62828);
    default:
      return const Color(0xFF616161); // Pending, Not Started, unknown
  }
}

Color priorityTone(String? p) {
  switch (p) {
    case 'Critical':
      return const Color(0xFFB71C1C);
    case 'High':
      return const Color(0xFFE65100);
    case 'Medium':
      return const Color(0xFFF9A825);
    case 'Low':
      return const Color(0xFF2E7D32);
    default:
      return const Color(0xFF757575);
  }
}

class Badge2 extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const Badge2(this.text, this.color, {super.key, this.icon});

  factory Badge2.status(String? s) => Badge2(s ?? '-', statusTone(s));
  factory Badge2.priority(String? p) =>
      Badge2(p ?? 'No priority', priorityTone(p));

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Fulfillment progress: label and % on top, pink bar, "x of y" below.
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
  Widget build(BuildContext context) {
    final pct = (percent ?? (needed > 0 ? delivered * 100 / needed : 0))
        .toDouble();
    const small = TextStyle(fontSize: 12, color: Brand.muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Fulfillment Progress', style: small)),
            Text(
              '${pct.toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: (pct / 100).clamp(0, 1),
            minHeight: 8,
            color: Brand.pink,
            backgroundColor: const Color(0xFFEEF0F3),
          ),
        ),
        const SizedBox(height: 4),
        Text('$delivered of $needed delivered', style: small),
      ],
    );
  }
}

/// Wireframe stat card: label, big number, note; tinted icon box top right.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;
  final String? note;
  const StatTile(
    this.label,
    this.value,
    this.icon, {
    super.key,
    this.color,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Brand.pink;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontSize: 13, color: Brand.muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Brand.ink,
                    ),
                  ),
                  if (note != null)
                    Text(
                      note!,
                      style: const TextStyle(fontSize: 11, color: Brand.muted),
                    ),
                ],
              ),
            ),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: c, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

/// Grid of stat tiles: 2 per row on phones, up to 4 on wide screens.
class StatGrid extends StatelessWidget {
  final List<StatTile> tiles;
  const StatGrid(this.tiles, {super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 900 ? 4 : (c.maxWidth >= 600 ? 3 : 2);
        final w = (c.maxWidth - 12 * (cols - 1)) / cols;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final t in tiles) SizedBox(width: w, child: t)],
        );
      },
    );
  }
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

class EmptyState extends StatelessWidget {
  final String text;
  final IconData icon;
  const EmptyState(this.text, {super.key, this.icon = Icons.inbox_outlined});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(icon, size: 44, color: Colors.grey),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
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
          if (!snap.hasData) {
            return ListView(
              children: const [
                Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            );
          }
          final bad = snap.data!.where((r) => !r.ok).toList();
          if (bad.isNotEmpty) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                EmptyState(
                  bad.first.status == 0
                      ? 'Cannot reach the server.\nIs uvicorn running?'
                      : 'Error ${bad.first.status}: ${bad.first.errorText}',
                  icon: Icons.cloud_off_outlined,
                ),
                Center(
                  child: OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
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
      backgroundColor: r.ok ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
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
