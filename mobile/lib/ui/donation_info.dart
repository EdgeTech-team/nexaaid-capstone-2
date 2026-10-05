import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import 'input_formatters.dart';
import 'upload_field.dart';
import 'widgets.dart';

/// Barangay donation-sending info (adviser item 7).
///
/// DISPLAY ONLY (manuscript Scope Limitation #5): NexaAid never processes,
/// holds or verifies money. Backend: api/v1/donation_info_routes.py.

const donationNote =
    'NexaAid does not process or verify payments. Send directly to the barangay.';

const donationProviders = ['GCash', 'Maya', 'Bank', 'Other'];

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

/// What donors see: QR (if any), provider, account, instructions, and
/// always the "NexaAid does not process payments" note.
class DonationInfoCard extends StatelessWidget {
  final Map? info;
  final String title;
  const DonationInfoCard({
    super.key,
    required this.info,
    this.title = 'Send money directly to the barangay',
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final i = info;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: t.titleMedium),
          Gaps.v8,
          if (i == null)
            Text(
              'No donation info yet.',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            )
          else ...[
            if (i['qr_url'] != null) ...[
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: Image.network(
                    '${api.baseUrl}${i['qr_url']}',
                    height: 200,
                    semanticLabel: 'Donation QR code',
                    errorBuilder: (_, _, _) =>
                        const Text('QR image unavailable'),
                  ),
                ),
              ),
              Gaps.v12,
            ],
            if (i['account_number'] != null)
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${i['provider'] ?? ''}', style: t.labelLarge),
                        SelectableText(
                          '${i['account_number']}',
                          style: t.titleMedium,
                        ),
                        if (i['account_name'] != null)
                          Text('${i['account_name']}', style: t.bodyMedium),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy account number',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: '${i['account_number']}'),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Account number copied')),
                      );
                    },
                  ),
                ],
              )
            else if (i['provider'] != null)
              Text('${i['provider']}', style: t.labelLarge),
            if (i['instructions'] != null) ...[
              Gaps.v8,
              Text('${i['instructions']}', style: t.bodyMedium),
            ],
          ],
          Gaps.v12,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: cs.onSurfaceVariant),
              Gaps.h8,
              Expanded(
                child: Text(
                  donationNote,
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// UC-D2: the report's donation info (override or barangay default), for
/// donors and guests. Shows nothing when the barangay hasn't added any.
class ReportDonationInfo extends StatelessWidget {
  final int reportId;
  const ReportDonationInfo({super.key, required this.reportId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ApiResult>(
      future: api.get('/reports/$reportId/donation-info'),
      builder: (context, snap) {
        if (!snap.hasData) return const Skeleton(height: 96);
        final r = snap.data!;
        if (!r.ok || r.json['info'] == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: DonationInfoCard(info: r.json['info'] as Map),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

/// Values of the donation info form, with the same checks as the backend
/// (schemas/donation_info_schema.py).
class DonationInfoController extends ChangeNotifier {
  String? provider;
  final accountName = TextEditingController();
  final accountNumber = TextEditingController();
  final instructions = TextEditingController();
  String? qrFileId;
  String? qrUrl; // current QR, for the preview
  int uploadKey = 0;

  void load(Map? info) {
    provider = info?['provider'] as String?;
    accountName.text = '${info?['account_name'] ?? ''}';
    accountNumber.text = '${info?['account_number'] ?? ''}';
    instructions.text = '${info?['instructions'] ?? ''}';
    qrFileId = info?['qr_file_id'] as String?;
    qrUrl = info?['qr_url'] as String?;
    uploadKey++;
    notifyListeners();
  }

  void setProvider(String? v) {
    provider = v;
    notifyListeners();
  }

  void setQr(UploadedFile? f) {
    qrFileId = f?.fileId;
    qrUrl = f?.url;
    notifyListeners();
  }

  void removeQr() {
    qrFileId = null;
    qrUrl = null;
    uploadKey++;
    notifyListeners();
  }

  String? accountNumberRule(String? v) {
    final n = (v ?? '').trim();
    if (n.isEmpty) return null;
    switch (provider) {
      case null:
        return 'Choose the provider first';
      case 'GCash':
      case 'Maya':
        return RegExp(r'^09\d{9}$').hasMatch(n)
            ? null
            : 'Mobile number, 11 digits, e.g. 09171234567';
      case 'Bank':
        return RegExp(r'^[0-9][0-9 \-]{4,28}[0-9]$').hasMatch(n)
            ? null
            : '6-30 digits (spaces and hyphens allowed)';
      default:
        return n.length < 3 || n.length > 50 ? '3-50 characters' : null;
    }
  }

  String? accountNameRule(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) {
      return accountNumber.text.trim().isEmpty
          ? null
          : 'Enter the account name';
    }
    return s.length < 2 || s.length > 100 ? '2-100 characters' : null;
  }

  String? instructionsRule(String? v) {
    final s = (v ?? '').trim();
    return s.isNotEmpty && s.length < 5 ? 'At least 5 characters' : null;
  }

  /// Form-level rule: QR, account number or instructions.
  String? get missing =>
      qrFileId == null &&
          accountNumber.text.trim().isEmpty &&
          instructions.text.trim().isEmpty
      ? 'Add a QR code, an account number, or instructions'
      : null;

  Map<String, dynamic> toJson() {
    String? v(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    return {
      'provider': provider,
      'account_name': v(accountName),
      'account_number': v(accountNumber),
      'instructions': v(instructions),
      'qr_file_id': qrFileId,
    };
  }

  @override
  void dispose() {
    accountName.dispose();
    accountNumber.dispose();
    instructions.dispose();
    super.dispose();
  }
}

/// Provider, account name, account number, instructions and an optional
/// QR image. Not always a QR (adviser item 7).
class DonationInfoFields extends StatelessWidget {
  final DonationInfoController c;
  final bool showMissing;
  const DonationInfoFields({
    super.key,
    required this.c,
    this.showMissing = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String?>(
            key: ValueKey('provider-${c.uploadKey}'),
            initialValue: c.provider,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final p in donationProviders)
                DropdownMenuItem(value: p, child: Text(p)),
            ],
            onChanged: c.setProvider,
          ),
          Gaps.v16,
          AppTextField(
            controller: c.accountName,
            label: 'Account name',
            icon: Icons.person_outline,
            validator: c.accountNameRule,
          ),
          Gaps.v16,
          AppTextField(
            key: ValueKey('number-${c.provider}'),
            controller: c.accountNumber,
            label: 'Account number',
            icon: Icons.numbers,
            hint: c.provider == 'GCash' || c.provider == 'Maya'
                ? '09171234567'
                : null,
            keyboardType: c.provider == 'Other'
                ? TextInputType.text
                : TextInputType.number,
            inputFormatters: c.provider == 'GCash' || c.provider == 'Maya'
                ? phoneFormatters
                : null,
            validator: c.accountNumberRule,
          ),
          Gaps.v16,
          AppTextField(
            controller: c.instructions,
            label: 'Instructions (optional)',
            hint: 'e.g. Put your name and the report number in the message.',
            maxLines: 3,
            maxLength: 500,
            validator: c.instructionsRule,
          ),
          Gaps.v16,
          if (c.qrUrl != null) ...[
            Text('Current QR code', style: t.labelLarge),
            Gaps.v8,
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Image.network(
                    '${api.baseUrl}${c.qrUrl}',
                    height: 96,
                    errorBuilder: (_, _, _) => const Icon(Icons.qr_code_2),
                  ),
                ),
                Gaps.h12,
                AppButton(
                  'Remove QR',
                  variant: AppButtonVariant.text,
                  icon: Icons.delete_outline,
                  onPressed: c.removeQr,
                ),
              ],
            ),
            Gaps.v16,
          ],
          UploadField(
            key: ValueKey('qr-${c.uploadKey}'),
            label: c.qrUrl == null
                ? 'QR code (optional)'
                : 'Replace QR code (optional)',
            purpose: 'barangay_donation_qr',
            allowPdf: false,
            helperText: 'Public: donors and guests see this image.',
            onChanged: (f) {
              if (f != null) c.setQr(f);
            },
          ),
          if (showMissing && c.missing != null) ...[
            Gaps.v8,
            Text(c.missing!, style: t.bodySmall?.copyWith(color: cs.error)),
          ],
        ],
      ),
    );
  }
}

/// Barangay Receiving Representative: edit their own barangay's info.
/// Administrator: pick any barangay.
class BarangayDonationInfoScreen extends StatefulWidget {
  /// Opened from the Administrator overview (has its own app bar).
  final bool standalone;
  const BarangayDonationInfoScreen({super.key, this.standalone = false});

  @override
  State<BarangayDonationInfoScreen> createState() =>
      _BarangayDonationInfoScreenState();
}

class _BarangayDonationInfoScreenState
    extends State<BarangayDonationInfoScreen> {
  String? brgyId;

  bool get isAdmin => api.role == Roles.admin;

  @override
  Widget build(BuildContext context) {
    final body = Loader(
      load: [isAdmin ? api.lookupsResult : () => api.get('/auth/me')],
      builder: (context, data) {
        final m = Map<String, dynamic>.from(data[0] as Map);
        if (!isAdmin) {
          final own = m['assigned_barangay_id'];
          if (own == null) {
            return const EmptyView(
              icon: Icons.location_off_outlined,
              title: 'No assigned barangay',
              message: 'Ask the Administrator to set your barangay first.',
            );
          }
          return _BarangayInfoEditor(
            key: ValueKey(own),
            barangayId: own as int,
          );
        }
        final names = Names(m);
        return ListView(
          padding: Space.page,
          children: [
            LookupDropdown(
              list: 'barangays',
              label: 'Barangay',
              value: brgyId,
              names: names,
              onChanged: (v) => setState(() => brgyId = v),
            ),
            if (brgyId == null)
              const EmptyView(
                compact: true,
                icon: Icons.account_balance_wallet_outlined,
                title: 'Choose a barangay',
                message: 'Then add or edit where donors can send money.',
              )
            else
              _BarangayInfoEditor(
                key: ValueKey(brgyId),
                barangayId: int.parse(brgyId!),
                embedded: true,
              ),
          ],
        );
      },
    );
    return widget.standalone
        ? Scaffold(
            appBar: AppBar(title: const Text('Barangay donation info')),
            body: body,
          )
        : body;
  }
}

class _BarangayInfoEditor extends StatefulWidget {
  final int barangayId;
  final bool embedded; // inside the admin's ListView
  const _BarangayInfoEditor({
    super.key,
    required this.barangayId,
    this.embedded = false,
  });

  @override
  State<_BarangayInfoEditor> createState() => _BarangayInfoEditorState();
}

class _BarangayInfoEditorState extends State<_BarangayInfoEditor> {
  final _form = GlobalKey<FormState>();
  final c = DonationInfoController();
  late Future<ApiResult> _load = _fetch();
  Map? saved;
  bool busy = false;
  bool tried = false;

  Future<ApiResult> _fetch() async {
    final r = await api.get('/barangays/${widget.barangayId}/donation-info');
    if (r.ok) {
      saved = r.json['info'] as Map?;
      c.load(saved);
    }
    return r;
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => tried = true);
    if (!_form.currentState!.validate() || c.missing != null) return;
    setState(() => busy = true);
    final r = await act(
      context,
      () => api.send(
        'PUT',
        '/barangays/${widget.barangayId}/donation-info',
        body: c.toJson(),
      ),
      success:
          'Donation info saved. Donors see it on this barangay\'s reports.',
    );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r.ok) {
        saved = r.json['info'] as Map?;
        c.load(saved);
        tried = false;
      }
    });
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove donation info?'),
        content: const Text(
          'Donors will no longer see where to send money for this barangay.',
        ),
        actions: [
          AppButton(
            'Cancel',
            variant: AppButtonVariant.text,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          AppButton(
            'Remove',
            variant: AppButtonVariant.danger,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r = await act(
      context,
      () => api.send('DELETE', '/barangays/${widget.barangayId}/donation-info'),
      success: 'Donation info removed',
    );
    if (r.ok && mounted) {
      setState(() {
        saved = null;
        c.load(null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ApiResult>(
      future: _load,
      builder: (context, snap) {
        if (!snap.hasData) return const SkeletonList();
        final r = snap.data!;
        if (!r.ok) {
          return ErrorView.forStatus(
            r.status,
            r.errorText,
            onRetry: () => setState(() => _load = _fetch()),
          );
        }
        final children = [
          if (!widget.embedded)
            PageHeader(
              'Donation info: ${r.json['barangay_name']}',
              subtitle:
                  'Where donors can send money directly to your barangay. '
                  'NexaAid only shows it; it never handles the money.',
            ),
          SectionHeader('What donors see'),
          DonationInfoCard(info: saved),
          SectionHeader('Edit'),
          Form(
            key: _form,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: DonationInfoFields(c: c, showMissing: tried),
          ),
          Gaps.v16,
          AppButton(
            'Save donation info',
            key: const ValueKey('save-donation-info'),
            icon: Icons.save_outlined,
            loading: busy,
            expand: true,
            onPressed: _save,
          ),
          if (saved != null) ...[
            Gaps.v8,
            AppButton(
              'Remove donation info',
              variant: AppButtonVariant.text,
              expand: true,
              onPressed: _remove,
            ),
          ],
          Gaps.v24,
        ];
        return widget.embedded
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              )
            : ListView(padding: Space.page, children: children);
      },
    );
  }
}

/// UC-CD1: inside New report. Shows the chosen barangay's info and lets
/// the CSWS Disaster Unit use different info for this report only.
/// UC-CD1: inside New report. Shows the chosen barangay's donation info.
class NewReportDonationInfo extends StatefulWidget {
  final String? barangayId;
  const NewReportDonationInfo({super.key, required this.barangayId});

  @override
  State<NewReportDonationInfo> createState() => NewReportDonationInfoState();
}

class NewReportDonationInfoState extends State<NewReportDonationInfo> {
  Future<ApiResult>? _load;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(NewReportDonationInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.barangayId != widget.barangayId) _fetch();
  }

  void _fetch() {
    final id = widget.barangayId;
    _load = id == null ? null : api.get('/barangays/$id/donation-info');
  }

  @override
  Widget build(BuildContext context) {
    if (_load == null) {
      return const EmptyView(
        compact: true,
        icon: Icons.account_balance_wallet_outlined,
        title: 'Choose a barangay to see its donation info',
      );
    }
    return FutureBuilder<ApiResult>(
      future: _load,
      builder: (context, snap) {
        if (!snap.hasData) return const Skeleton(height: 96);
        final r = snap.data!;
        final info = r.ok ? r.json['info'] as Map? : null;
        return DonationInfoCard(
          info: info,
          title: 'Barangay ${r.ok ? r.json['barangay_name'] : ''} default',
        );
      },
    );
  }
}
