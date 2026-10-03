import 'package:flutter/material.dart';

import 'ui/upload_field.dart';

/// Developer tools > Uploads: try UploadField with every purpose and see
/// exactly what the backend returned. Used for testing, not by real users.
class UploadDemoTab extends StatefulWidget {
  const UploadDemoTab({super.key});

  @override
  State<UploadDemoTab> createState() => _UploadDemoTabState();
}

class _UploadDemoTabState extends State<UploadDemoTab> {
  String _last = 'Nothing uploaded yet.';

  void _show(String purpose, UploadedFile? f) {
    setState(() {
      _last = f == null
          ? '$purpose: no file attached'
          : '$purpose\n'
                'file_id: ${f.fileId}\n'
                'url: ${f.url}\n'
                'type: ${f.contentType}\n'
                'claim_token: ${f.claimToken ?? "(none, you are logged in)"}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        UploadField(
          label: 'Valid ID (front)',
          purpose: 'id_front',
          helperText: 'Private: only you and the Administrator can see it.',
          onChanged: (f) => _show('id_front', f),
        ),
        const SizedBox(height: 20),
        UploadField(
          label: 'Legitimacy document',
          purpose: 'legitimacy_document',
          helperText: 'Private. Organizations upload this at registration.',
          onChanged: (f) => _show('legitimacy_document', f),
        ),
        const SizedBox(height: 20),
        UploadField(
          label: 'Barangay donation QR',
          purpose: 'barangay_donation_qr',
          allowPdf: false,
          helperText:
              'Public. Only the barangay rep, Disaster Unit or Admin may upload.',
          onChanged: (f) => _show('barangay_donation_qr', f),
        ),
        const SizedBox(height: 24),
        Text('Last result', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(_last),
          ),
        ),
      ],
    );
  }
}