import 'package:flutter/material.dart';

/// problema_napud 2.2: the sitios a report covers, one dropdown per sitio,
/// with "Add another sitio".
///
/// [options] is value -> label of the CHOSEN barangay's sitios only, so the
/// list always follows the barangay. A sitio picked in one row is not
/// offered again in another. [rows] holds one value per row ('' = not
/// chosen); a single empty row means the whole barangay.
class SitioPicker extends StatelessWidget {
  final Map<String, String> options;
  final List<String> rows;
  final ValueChanged<List<String>> onChanged;

  const SitioPicker({
    super.key,
    required this.options,
    required this.rows,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final list = rows.isEmpty ? const [''] : rows;
    final single = list.length == 1;
    final full = list.every((r) => r.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < list.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == list.length - 1 ? 0 : 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('sitio-row-$i-${list[i]}-${list.length}'),
                    initialValue: options.containsKey(list[i]) ? list[i] : '',
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: single ? 'Sitio' : 'Sitio ${i + 1}',
                      helperText: single
                          ? (options.isEmpty
                                ? 'No sitios saved for this barangay'
                                : 'Choose a sitio, or keep Whole barangay')
                          : null,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(
                          single ? 'Whole barangay' : 'Choose a sitio',
                        ),
                      ),
                      for (final e in options.entries)
                        if (e.key == list[i] || !list.contains(e.key))
                          DropdownMenuItem(
                            value: e.key,
                            child: Text(
                              e.value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                    ],
                    onChanged: (v) => onChanged([...list]..[i] = v ?? ''),
                    validator: (v) => !single && (v ?? '').isEmpty
                        ? 'Choose a sitio, or remove this row'
                        : null,
                  ),
                ),
                if (!single)
                  IconButton(
                    tooltip: 'Remove this sitio',
                    onPressed: () => onChanged([...list]..removeAt(i)),
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
        if (options.length > 1)
          TextButton.icon(
            key: const Key('add-sitio'),
            // Choose the current row first; stop when every sitio is listed.
            onPressed: full && list.length < options.length
                ? () => onChanged([...list, ''])
                : null,
            icon: const Icon(Icons.add),
            label: const Text('Add another sitio'),
          ),
      ],
    );
  }
}
