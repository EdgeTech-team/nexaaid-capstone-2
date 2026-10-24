import 'package:flutter/material.dart';

import 'widgets.dart';

// F-15: items typed in by donors and guests ("Something else") wait here
// until CSWS Main Office or the Administrator approves them. Until then
// they are in no dropdown; the donations that use them keep them.

/// Dashboard card, shown only while something is waiting.
class PendingItemsCard extends StatefulWidget {
  const PendingItemsCard({super.key});

  @override
  State<PendingItemsCard> createState() => _PendingItemsCardState();
}

class _PendingItemsCardState extends State<PendingItemsCard> {
  int _count = 0;

  Future<void> _load() async {
    final r = await api.get('/items/pending');
    if (!mounted) return;
    setState(
      () => _count = r.ok && r.json is List ? (r.json as List).length : 0,
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: AppCard(
        onTap: () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const PendingItemsScreen()));
          _load();
        },
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.new_releases_outlined, color: cs.primary),
          title: Text('New items to review ($_count)'),
          subtitle: const Text(
            'Typed in by donors. Not in the item list until you approve them.',
          ),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}

class PendingItemsScreen extends StatelessWidget {
  const PendingItemsScreen({super.key});

  Future<void> _approve(
    BuildContext context,
    Map i, {
    bool rename = false,
  }) async {
    var body = <String, dynamic>{};
    if (rename) {
      final v = await formDialog(
        context,
        title: 'Rename and approve',
        message: 'The name everyone will see in the item list.',
        fields: [
          DialogField('name', 'Item name', initial: '${i['item_name']}'),
        ],
        confirm: 'Approve',
      );
      if (v == null || !context.mounted) return;
      body = {'item_name': v['name']!.trim()};
    }
    await act(
      context,
      () => api.post('/items/${i['item_id']}/approve', body: body),
      success: 'Item approved',
    );
  }

  Future<void> _reject(BuildContext context, Map i) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reject "${i['item_name']}"?'),
        content: const Text(
          'It stays on the donations that already use it, but nobody can '
          'choose it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
    await act(
      context,
      () => api.post('/items/${i['item_id']}/reject', body: const {}),
      success: 'Item rejected',
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New items to review')),
      body: Loader(
        load: [() => api.get('/items/pending')],
        builder: (context, data) {
          final items = (data[0] as List).cast<Map>();
          if (items.isEmpty) {
            return ListView(
              children: const [
                EmptyView(
                  icon: Icons.check_circle_outline,
                  title: 'Nothing to review.',
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final i in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${i['item_name']}', style: t.titleMedium),
                        Text(
                          'Unit: ${i['unit']} · used in '
                          '${i['donation_lines']} donation item(s)',
                        ),
                        Gaps.v8,
                        Wrap(
                          spacing: Space.xs,
                          runSpacing: Space.xs,
                          children: [
                            AppButton(
                              'Approve',
                              icon: Icons.check,
                              variant: AppButtonVariant.tonal,
                              onPressed: () => _approve(context, i),
                            ),
                            AppButton(
                              'Rename',
                              icon: Icons.edit_outlined,
                              variant: AppButtonVariant.secondary,
                              onPressed: () =>
                                  _approve(context, i, rename: true),
                            ),
                            AppButton(
                              'Reject',
                              icon: Icons.block,
                              variant: AppButtonVariant.text,
                              onPressed: () => _reject(context, i),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
