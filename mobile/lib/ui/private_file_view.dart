import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../api.dart';
import '../design/design.dart';

/// One private uploaded file (valid ID, legitimacy document, ...) for the
/// Administrator's review (UC-A1, UC-A2 step 4).
///
/// The bytes are fetched with the login token from GET /uploads/{file_id},
/// which only answers the owner or an Administrator (RA 10173). Nothing is
/// saved to the phone: images are shown from memory, PDFs open in the
/// in-app viewer.
class PrivateFileTile extends StatefulWidget {
  final String label;
  final String url; // relative, /uploads/<file_id>
  final String contentType;

  const PrivateFileTile({
    super.key,
    required this.label,
    required this.url,
    required this.contentType,
  });

  bool get isPdf => contentType == 'application/pdf';

  @override
  State<PrivateFileTile> createState() => _PrivateFileTileState();
}

class _PrivateFileTileState extends State<PrivateFileTile> {
  late Future<(int, Uint8List?)> _bytes = _load();

  Future<(int, Uint8List?)> _load() => Api.instance.download(widget.url);

  void _retry() => setState(() => _bytes = _load());

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.label, style: t.labelLarge),
        Gaps.v8,
        widget.isPdf ? _pdfCard(context) : _image(context),
      ],
    );
  }

  Widget _pdfCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PdfViewScreen(title: widget.label, url: widget.url),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.picture_as_pdf_outlined, color: cs.primary, size: 32),
          Gaps.h12,
          const Expanded(child: Text('PDF document. Tap to open.')),
          Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }

  Widget _image(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<(int, Uint8List?)>(
      future: _bytes,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Skeleton(height: 180, width: double.infinity);
        }
        final (status, bytes) = snap.data!;
        if (bytes == null) {
          return _FileError(status: status, onRetry: _retry);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: Material(
            color: cs.surfaceContainerHighest,
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      _ImageViewScreen(title: widget.label, bytes: bytes),
                ),
              ),
              child: SizedBox(
                height: 180,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  semanticLabel: widget.label,
                  errorBuilder: (_, _, _) =>
                      const _FileError(status: -1, onRetry: null),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FileError extends StatelessWidget {
  final int status; // 0 = no connection, -1 = file can't be displayed
  final VoidCallback? onRetry;
  const _FileError({required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final message = switch (status) {
      0 => 'Can\'t reach the server. Check that uvicorn is running.',
      -1 => 'This file can\'t be displayed. Treat it as unreadable.',
      404 => 'File not found. It may have been removed.',
      _ => 'Couldn\'t load the file (error $status).',
    };
    return AppCard(
      child: Row(
        children: [
          Icon(Icons.broken_image_outlined, color: cs.error),
          Gaps.h12,
          Expanded(child: Text(message)),
          if (onRetry != null)
            AppButton(
              'Try again',
              variant: AppButtonVariant.text,
              onPressed: onRetry,
            ),
        ],
      ),
    );
  }
}

class _ImageViewScreen extends StatelessWidget {
  final String title;
  final Uint8List bytes;
  const _ImageViewScreen({required this.title, required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.memory(bytes, semanticLabel: title)),
      ),
    );
  }
}

/// Full-screen viewer for a private PDF (pdfrx). Pinch to zoom.
class PdfViewScreen extends StatefulWidget {
  final String title;
  final String url;
  const PdfViewScreen({super.key, required this.title, required this.url});

  @override
  State<PdfViewScreen> createState() => _PdfViewScreenState();
}

class _PdfViewScreenState extends State<PdfViewScreen> {
  late Future<(int, Uint8List?)> _bytes = Api.instance.download(widget.url);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: FutureBuilder<(int, Uint8List?)>(
        future: _bytes,
        builder: (context, snap) {
          if (!snap.hasData) return const SkeletonList();
          final (status, bytes) = snap.data!;
          if (bytes == null) {
            return ErrorView.forStatus(
              status,
              'The document could not be downloaded.',
              onRetry: () =>
                  setState(() => _bytes = Api.instance.download(widget.url)),
            );
          }
          return PdfViewer.data(bytes, sourceName: widget.url);
        },
      ),
    );
  }
}
