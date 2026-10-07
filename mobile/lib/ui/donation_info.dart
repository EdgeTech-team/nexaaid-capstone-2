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

/// Several ways to give (J3): one card per payment method, oldest first.
/// With no methods it shows the empty card.
class DonationMethodsList extends StatelessWidget {
  final List methods;
  final String? heading;
  const DonationMethodsList({super.key, required this.methods, this.heading});

  static String titleOf(Map m) {
    if (m['provider'] != null) return '${m['provider']}';
    return m['qr_url'] != null ? 'Donation QR' : 'Instructions';
  }

  @override
  Widget build(BuildContext context) {
    if (methods.isEmpty) {
      return DonationInfoCard(
        info: null,
        title: heading ?? 'Send money directly to the barangay',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (heading != null) ...[
          Text(heading!, style: Theme.of(context).textTheme.titleMedium),
          Gaps.v8,
        ],
        for (final m in methods)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: DonationInfoCard(info: m as Map, title: titleOf(m)),
          ),
      ],
    );
  }
}

/// UC-D2: the report's donation info (its override, else all of the
/// barangay's methods), for donors and guests. Shows nothing when there is none.
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
        if (!r.ok) return const SizedBox.shrink();
        final methods = (r.json['methods'] as List?) ?? const [];
        final info = r.json['info'];
        // A report override replaces the list (the server sends methods: []).
        final shown = methods.isNotEmpty ? methods : [?info];
        if (shown.isEmpty) return const SizedBox.shrink();
        // Shown below the donated items (4.1), so the space goes on top.
        return Padding(
          padding: const EdgeInsets.only(top: Space.lg),
          child: DonationMethodsList(
            methods: shown,
            heading: 'Send money directly to the barangay',
          ),
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
  late Future<ApiResult> _load = _fetch();
  List methods = [];

  Future<ApiResult> _fetch() async {
    final r = await api.get('/barangays/${widget.barangayId}/donation-info');
    if (r.ok) methods = (r.json['methods'] as List?) ?? [];
    return r;
  }

  void _reload() {
    setState(() {
      _load = _fetch();
    });
  }

  Future<void> _openForm([Map? method]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            _MethodFormPage(barangayId: widget.barangayId, method: method),
      ),
    );
    if (saved == true && mounted) _reload();
  }

  Future<void> _remove(Map m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this payment method?'),
        content: Text(
          'Donors will no longer see ${DonationMethodsList.titleOf(m)} '
          'for this barangay.',
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
      () => api.send(
        'DELETE',
        '/barangays/${widget.barangayId}/donation-info/methods/${m['method_id']}',
      ),
      success: 'Payment method removed',
    );
    if (r.ok && mounted) _reload();
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
            onRetry: _reload,
          );
        }
        final children = [
          if (!widget.embedded)
            PageHeader(
              'Donation info: ${r.json['barangay_name']}',
              subtitle:
                  'Ways donors can send money directly to your barangay. '
                  'Add one entry per GCash, Maya or bank account. '
                  'NexaAid only shows them; it never handles the money.',
            ),
          SectionHeader('Payment methods'),
          if (methods.isEmpty)
            const DonationInfoCard(info: null, title: 'No payment methods yet')
          else
            for (final m in methods) ...[
              DonationInfoCard(
                info: m as Map,
                title: DonationMethodsList.titleOf(m),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AppButton(
                    'Edit',
                    variant: AppButtonVariant.text,
                    onPressed: () => _openForm(m),
                  ),
                  Gaps.h8,
                  AppButton(
                    'Remove',
                    variant: AppButtonVariant.text,
                    onPressed: () => _remove(m),
                  ),
                ],
              ),
              Gaps.v8,
            ],
          Gaps.v8,
          AppButton(
            'Add payment method',
            key: const ValueKey('add-donation-method'),
            icon: Icons.add,
            expand: true,
            onPressed: () => _openForm(),
          ),
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

/// Add or edit one payment method (J3).
class _MethodFormPage extends StatefulWidget {
  final int barangayId;
  final Map? method; // null = add a new one
  const _MethodFormPage({required this.barangayId, this.method});

  @override
  State<_MethodFormPage> createState() => _MethodFormPageState();
}

class _MethodFormPageState extends State<_MethodFormPage> {
  final _form = GlobalKey<FormState>();
  final c = DonationInfoController();
  bool busy = false;
  bool tried = false;

  @override
  void initState() {
    super.initState();
    c.load(widget.method);
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
    final base = '/barangays/${widget.barangayId}/donation-info/methods';
    final editing = widget.method != null;
    final r = await act(
      context,
      () => api.send(
        editing ? 'PUT' : 'POST',
        editing ? '$base/${widget.method!['method_id']}' : base,
        body: c.toJson(),
      ),
      success: editing ? 'Payment method updated' : 'Payment method added',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.method == null ? 'Add payment method' : 'Edit payment method',
        ),
      ),
      body: ListView(
        padding: Space.page,
        children: [
          Form(
            key: _form,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: DonationInfoFields(c: c, showMissing: tried),
          ),
          Gaps.v16,
          AppButton(
            'Save',
            key: const ValueKey('save-donation-info'),
            icon: Icons.save_outlined,
            loading: busy,
            expand: true,
            onPressed: _save,
          ),
          Gaps.v24,
        ],
      ),
    );
  }
}

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
        final methods = r.ok ? ((r.json['methods'] as List?) ?? const []) : const [];
        return DonationMethodsList(
          methods: methods,
          heading:
              'Barangay ${r.ok ? r.json['barangay_name'] : ''} donation info',
        );
      },
    );
  }
}
