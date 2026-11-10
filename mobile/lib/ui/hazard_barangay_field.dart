import 'package:flutter/material.dart';

import 'widgets.dart';

/// NF-004: the report form's barangay field. For a location-specific
/// disaster type (Landslide, Storm Surge) the barangays known to be prone
/// to it come first with a `Prone to <type>` tag; any other barangay can
/// still be picked after a confirm dialog. A general type (Flood, Typhoon,
/// Earthquake, Fire...) shows the plain list. Never blocks a barangay: the
/// server accepts any of them.
class HazardBarangayField extends StatefulWidget {
  final Names names;
  final String? typeId;
  final String? value;
  final ValueChanged<String?> onChanged;
  const HazardBarangayField({
    super.key,
    required this.names,
    required this.typeId,
    required this.value,
    required this.onChanged,
  });

  @override
  State<HazardBarangayField> createState() => _HazardBarangayFieldState();
}

class _HazardBarangayFieldState extends State<HazardBarangayField> {
  /// Prone barangay ids per disaster type id, loaded once per type.
  static final _prone = <String, Future<Set<String>>>{};

  /// Rebuilds the dropdown after "Choose another", so it shows the
  /// barangay that was picked before.
  int _rev = 0;

  bool get _locationSpecific =>
      widget.typeId != null &&
      widget.names
          .rows('disaster_types')
          .any(
            (t) =>
                '${t['id']}' == widget.typeId &&
                t['is_location_specific'] == true,
          );

  String get _typeName =>
      widget.names.of('disaster_types', widget.typeId, fallback: 'it');

  Future<Set<String>> _load(String typeId) => _prone[typeId] ??= api
      .get('/lookups/barangays', query: {'disaster_type_id': typeId})
      .then((r) {
        if (!r.ok || r.json is! List) {
          _prone.remove(typeId); // asked again next time
          return <String>{};
        }
        return {
          for (final b in r.json as List)
            if (b is Map && b['is_hazard_prone'] == true) '${b['id']}',
        };
      });

  Widget _plain() => LookupDropdown(
    list: 'barangays',
    label: 'Barangay',
    value: widget.value,
    names: widget.names,
    onChanged: widget.onChanged,
  );

  @override
  Widget build(BuildContext context) {
    if (!_locationSpecific) return _plain();
    return FutureBuilder<Set<String>>(
      future: _load(widget.typeId!),
      builder: (context, snap) {
        final prone = snap.data;
        // Still loading, offline or no tagged barangays: the plain list,
        // so the form never waits on the suggestion.
        if (prone == null || prone.isEmpty) return _plain();
        return _tagged(prone);
      },
    );
  }

  Widget _tagged(Set<String> prone) {
    final rows = widget.names.rows('barangays')
      ..sort((a, b) {
        final pa = prone.contains('${a['id']}') ? 0 : 1;
        final pb = prone.contains('${b['id']}') ? 0 : 1;
        return pa != pb ? pa - pb : '${a['name']}'.compareTo('${b['name']}');
      });
    final picked = widget.value;
    // The picked barangay is not tagged for this type: picked after
    // "Continue", or the type changed afterwards. Only a note under the
    // field: the pick is kept and the form can still be submitted.
    final note = picked != null && !prone.contains(picked)
        ? '${widget.names.of('barangays', picked)} is not tagged as prone to $_typeName.'
        : null;
    return DropdownButtonFormField<String>(
      key: ValueKey('hazard-${widget.typeId}-$_rev'),
      initialValue: picked,
      isExpanded: true,
      items: [
        for (final r in rows)
          DropdownMenuItem(
            value: '${r['id']}',
            child: Row(
              children: [
                Expanded(
                  child: Text('${r['name']}', overflow: TextOverflow.ellipsis),
                ),
                if (prone.contains('${r['id']}'))
                  _ProneTag('Prone to $_typeName'),
              ],
            ),
          ),
      ],
      onChanged: (v) => _pick(v, prone),
      validator: (v) => v == null || v.isEmpty ? 'Please choose one' : null,
      decoration: InputDecoration(
        labelText: 'Barangay',
        helperText: note ?? 'Barangays prone to $_typeName are listed first.',
        helperMaxLines: 2,
      ),
    );
  }

  Future<void> _pick(String? v, Set<String> prone) async {
    if (v == null || prone.contains(v)) {
      widget.onChanged(v);
      return;
    }
    final name = widget.names.of('barangays', v);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Barangay not tagged'),
        content: Text('$name is not tagged as prone to $_typeName. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Choose another'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      widget.onChanged(v);
    } else {
      setState(() => _rev++);
    }
  }
}

/// "Prone to Landslide": a small pill in the theme's secondary colors
/// (yellow is reserved for Donate).
class _ProneTag extends StatelessWidget {
  final String text;
  const _ProneTag(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: Space.xs),
      padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: 2),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSecondaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
