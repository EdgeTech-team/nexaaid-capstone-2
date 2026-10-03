import 'package:flutter/material.dart';

import '../api.dart' show Roles;
import 'private_file_view.dart';
import 'widgets.dart';

/// UC-A1 Manage accounts: one account's details and uploaded documents.
/// For a donor the Administrator checks the valid ID (UC-D1 step 3) and
/// can deactivate the account if the ID is invalid (UC-A1 step 5).
class AccountDetailScreen extends StatefulWidget {
  final int userId;
  const AccountDetailScreen({super.key, required this.userId});

  @override
  State<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

const _purposeLabels = {
  'id_front': 'Valid ID (front)',
  'id_back': 'Valid ID (back)',
  'legitimacy_document': 'Supporting document',
  'employee_id_card': 'Employee ID card',
};

class _AccountDetailScreenState extends State<AccountDetailScreen> {
  bool busy = false;

  Future<void> _setActive(Map u, bool activate) async {
    if (!activate) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Deactivate this account?'),
          content: Text(
            '${u['first_name']} ${u['last_name']} will be logged out and '
            'cannot log in until you activate the account again.',
          ),
          actions: [
            AppButton(
              'Cancel',
              variant: AppButtonVariant.text,
              onPressed: () => Navigator.pop(ctx, false),
            ),
            AppButton(
              'Deactivate',
              variant: AppButtonVariant.danger,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => busy = true);
    await act(
      context,
      () => api.patch(
        '/admin/users/${widget.userId}',
        body: {'is_active': activate},
      ),
      success: activate ? 'Account activated' : 'Account deactivated',
    );
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: Loader(
        load: [
          () => api.get('/admin/users/${widget.userId}'),
          () => api.get('/admin/users/${widget.userId}/documents'),
        ],
        builder: (context, data) {
          final u = Map<String, dynamic>.from(data[0] as Map);
          final docs = (data[1] as List).cast<Map>();
          return _body(context, u, docs);
        },
      ),
    );
  }

  Widget _body(BuildContext context, Map<String, dynamic> u, List<Map> docs) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final active = u['is_active'] == true;
    final isDonor = u['role'] == Roles.donor;
    // Newest file per purpose (the list comes newest first).
    final latest = <String, Map>{};
    for (final d in docs) {
      latest.putIfAbsent('${d['purpose']}', () => d);
    }

    Widget row(String label, dynamic value) => Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text('${value ?? '-'}', style: t.bodyMedium)),
        ],
      ),
    );

    return ListView(
      padding: Space.page,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${u['first_name']} ${u['last_name']}',
                style: t.headlineSmall,
              ),
            ),
            StatusChip(
              active ? 'Active' : 'Cancelled',
              label: active ? 'Active' : 'Deactivated',
            ),
          ],
        ),
        Gaps.v16,
        AppCard(
          child: Column(
            children: [
              row('Role', u['role']),
              row('Email', u['email']),
              row('Mobile', u['contact_number']),
              if (u['assigned_barangay'] != null)
                row('Barangay', u['assigned_barangay']),
              if (u['organization'] != null)
                row(
                  'Organization',
                  '${u['organization']} (${u['organization_status']})',
                ),
              row('Registered', niceDate(u['created_at'])),
            ],
          ),
        ),
        if (isDonor) ...[
          const SectionHeader(
            'Valid ID',
            subtitle: 'Check that the ID is readable and matches the name.',
          ),
          row('ID type', u['id_type'] ?? 'Not given'),
          Gaps.v8,
          for (final p in const ['id_front', 'id_back'])
            Padding(
              padding: const EdgeInsets.only(bottom: Space.md),
              child: latest[p] == null
                  ? AppCard(
                      child: Row(
                        children: [
                          Icon(Icons.flag_outlined, color: cs.error),
                          Gaps.h12,
                          Expanded(
                            child: Text(
                              '${_purposeLabels[p]} missing. This account '
                              'registered before ID uploads existed.',
                            ),
                          ),
                        ],
                      ),
                    )
                  : PrivateFileTile(
                      label: _purposeLabels[p]!,
                      url: '${latest[p]!['url']}',
                      contentType: '${latest[p]!['content_type']}',
                    ),
            ),
        ],
        if (latest.keys.any((p) => !p.startsWith('id_'))) ...[
          const SectionHeader('Other documents'),
          for (final e in latest.entries)
            if (!e.key.startsWith('id_'))
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: PrivateFileTile(
                  label: _purposeLabels[e.key] ?? e.key,
                  url: '${e.value['url']}',
                  contentType: '${e.value['content_type']}',
                ),
              ),
        ],
        Gaps.v16,
        if (u['user_id'] != null)
          AppButton(
            active ? 'Deactivate account' : 'Activate account',
            key: const ValueKey('toggle-active'),
            icon: active ? Icons.person_off_outlined : Icons.person_outline,
            variant: active
                ? AppButtonVariant.danger
                : AppButtonVariant.primary,
            loading: busy,
            expand: true,
            onPressed: () => _setActive(u, !active),
          ),
        Gaps.v24,
      ],
    );
  }
}
