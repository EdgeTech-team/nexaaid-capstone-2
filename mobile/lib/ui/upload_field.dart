import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api.dart';

/// What POST /uploads sent back for one file
/// (backend: api/v1/upload_routes.py).
class UploadedFile {
  final String fileId;
  final String url; // relative, e.g. /uploads/<file_id>
  final String contentType;

  /// Only present when the file was uploaded before logging in
  /// (registration). Send it with the register request.
  final String? claimToken;

  const UploadedFile({
    required this.fileId,
    required this.url,
    required this.contentType,
    this.claimToken,
  });

  factory UploadedFile.fromJson(Map<String, dynamic> json) => UploadedFile(
    fileId: json['file_id'] as String,
    url: json['url'] as String,
    contentType: json['content_type'] as String,
    claimToken: json['claim_token'] as String?,
  );

  bool get isPdf => contentType == 'application/pdf';
}

enum _Status { empty, uploading, done, failed }

/// Lets the user take a photo, pick one from the gallery, or pick a PDF.
/// Uploads it right away and shows a preview.
///
/// [purpose] must match one in backend core/uploads.py PURPOSES:
/// id_front, id_back, legitimacy_document, barangay_donation_qr.
///
/// [onChanged] gets the uploaded file, or null while nothing valid is
/// attached (empty, uploading, failed, or removed). A form should only
/// allow submitting when it has received a non-null value.
///
/// Colors come from the app theme, so it follows whatever design the
/// team picks.
class UploadField extends StatefulWidget {
  final String label;
  final String purpose;
  final ValueChanged<UploadedFile?> onChanged;
  final bool allowPdf;
  final String? helperText;

  const UploadField({
    super.key,
    required this.label,
    required this.purpose,
    required this.onChanged,
    this.allowPdf = true,
    this.helperText,
  });

  @override
  State<UploadField> createState() => _UploadFieldState();
}

class _UploadFieldState extends State<UploadField> {
  static const _maxBytes = 5 * 1024 * 1024; // same limit as the backend

  _Status _status = _Status.empty;
  Uint8List? _bytes; // kept for the preview and for "Try again"
  String _name = '';
  bool _isImage = true;
  String? _error;

  // ---- 1. Ask where the file comes from -------------------------------
  Future<void> _choose() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheet, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheet, 'gallery'),
            ),
            if (widget.allowPdf)
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('Choose a PDF'),
                onTap: () => Navigator.pop(sheet, 'pdf'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return; // closed the sheet

    // ---- 2. Get the bytes ----------------------------------------------
    try {
      if (choice == 'pdf') {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
        if (file == null) return; // cancelled
        await _send(await file.readAsBytes(), file.name, isImage: false);
      } else {
        final photo = await ImagePicker().pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 2000, // shrinks big phone photos so they stay under 5 MB
          imageQuality: 85,
        );
        if (photo == null) return; // cancelled
        await _send(await photo.readAsBytes(), photo.name, isImage: true);
      }
    } catch (e) {
      _fail('Could not open the camera or files. ($e)');
    }
  }

  // ---- 3. Upload --------------------------------------------------------
  Future<void> _send(
    Uint8List bytes,
    String name, {
    required bool isImage,
  }) async {
    setState(() {
      _bytes = bytes;
      _name = name;
      _isImage = isImage;
      _error = null;
      _status = _Status.uploading;
    });
    widget.onChanged(null); // the old file doesn't count while uploading

    if (bytes.length > _maxBytes) {
      _fail('The file is larger than 5 MB.'); // check before wasting data
      return;
    }

    final r = await Api.instance.upload(
      purpose: widget.purpose,
      bytes: bytes,
      filename: name,
    );
    if (!mounted) return; // the screen was closed while uploading

    if (r.ok && r.json is Map) {
      setState(() => _status = _Status.done);
      widget.onChanged(
        UploadedFile.fromJson(Map<String, dynamic>.from(r.json as Map)),
      );
    } else {
      _fail(
        r.status == 0
            ? 'Cannot reach the server. Check your connection.'
            : r.errorText, // the backend's own message, e.g. "Only JPG, PNG..."
      );
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _status = _Status.failed;
      _error = message;
    });
  }

  void _retry() {
    final b = _bytes;
    if (b != null) _send(b, _name, isImage: _isImage);
  }

  void _remove() {
    setState(() {
      _status = _Status.empty;
      _bytes = null;
      _error = null;
    });
    widget.onChanged(null);
  }

  // ---- 4. Draw it --------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final failed = _status == _Status.failed;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.label, style: text.labelLarge),
        const SizedBox(height: 6),
        Semantics(
          button: _status == _Status.empty,
          label: widget.label,
          child: Material(
            color: cs.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: failed ? cs.error : cs.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _status == _Status.empty ? _choose : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _status == _Status.empty
                    ? _emptyContent(cs, text)
                    : _fileContent(cs, text),
              ),
            ),
          ),
        ),
        if (widget.helperText != null) ...[
          const SizedBox(height: 4),
          Text(
            widget.helperText!,
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _emptyContent(ColorScheme cs, TextTheme text) {
    return Row(
      children: [
        Icon(Icons.upload_file_outlined, size: 32, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.allowPdf ? 'Tap to add a photo or PDF' : 'Tap to add a photo',
                style: text.bodyLarge,
              ),
              Text(
                widget.allowPdf
                    ? 'JPG, PNG or PDF, up to 5 MB'
                    : 'JPG or PNG, up to 5 MB',
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _fileContent(ColorScheme cs, TextTheme text) {
    final preview = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 64,
        height: 64,
        child: _isImage && _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover)
            : ColoredBox(
                color: cs.primaryContainer,
                child: Icon(Icons.picture_as_pdf, color: cs.onPrimaryContainer),
              ),
      ),
    );

    final Widget statusLine = switch (_status) {
      _Status.uploading => const Padding(
        padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(),
      ),
      _Status.done => Row(
        children: [
          Icon(Icons.check_circle, size: 16, color: cs.primary),
          const SizedBox(width: 4),
          Text('Uploaded', style: text.bodySmall?.copyWith(color: cs.primary)),
        ],
      ),
      _ => Text(_error ?? '', style: text.bodySmall?.copyWith(color: cs.error)),
    };

    return Row(
      children: [
        preview,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              statusLine,
            ],
          ),
        ),
        if (_status == _Status.failed)
          TextButton(onPressed: _retry, child: const Text('Try again')),
        if (_status == _Status.done)
          TextButton(onPressed: _choose, child: const Text('Change')),
        if (_status != _Status.uploading)
          IconButton(
            tooltip: 'Remove',
            onPressed: _remove,
            icon: const Icon(Icons.close),
          ),
      ],
    );
  }
}