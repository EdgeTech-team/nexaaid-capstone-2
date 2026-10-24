// F-20: the Content-Security-Policy in web/_headers (Netlify) must keep
// allowing what the web app loads, and only the exact CDN paths.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart';
// The zxing-wasm version mobile_scanner loads for QR scanning on Firefox.
// ignore: implementation_imports
import 'package:mobile_scanner/src/web/web_library_versions.dart';

Map<String, List<String>> _csp() {
  final line = File('web/_headers')
      .readAsLinesSync()
      .map((l) => l.trim())
      .firstWhere((l) => l.startsWith('Content-Security-Policy'));
  final policy = line.substring(line.indexOf(':') + 1);
  return {
    for (final d
        in policy.split(';').map((d) => d.trim()).where((d) => d.isNotEmpty))
      d.split(RegExp(r'\s+')).first: d.split(RegExp(r'\s+')).skip(1).toList(),
  };
}

void main() {
  final csp = _csp();
  final api = Api.instance.baseUrl;
  final zxingScript =
      'https://cdn.jsdelivr.net/npm/zxing-wasm@$zxingWasmVersion/';
  final zxingWasm =
      'https://fastly.jsdelivr.net/npm/zxing-wasm@$zxingWasmVersion/';
  const canvasKit = 'https://www.gstatic.com/flutter-canvaskit/';
  const fonts = 'https://fonts.gstatic.com/s/';
  const tiles = 'https://tile.openstreetmap.org';

  test('Scripts: the app, CanvasKit and the pinned zxing-wasm only', () {
    expect(
      csp['script-src'],
      unorderedEquals(["'self'", "'wasm-unsafe-eval'", canvasKit, zxingScript]),
    );
  });

  test('Connections: API, CanvasKit, fonts, map tiles, zxing-wasm binary', () {
    expect(
      csp['connect-src'],
      containsAll([api, canvasKit, fonts, tiles, zxingWasm]),
    );
  });

  test('Images, fonts and workers', () {
    expect(csp['img-src'], containsAll([api, tiles, 'data:', 'blob:']));
    expect(csp['font-src'], contains(fonts));
    expect(csp['worker-src'], containsAll(["'self'", 'blob:']));
  });

  test('No whole-CDN or wildcard sources', () {
    final all = csp.values.expand((v) => v).toList();
    for (final host in [
      'https://cdn.jsdelivr.net',
      'https://fastly.jsdelivr.net',
      'https://www.gstatic.com',
      'https://fonts.gstatic.com',
      '*',
      'https:',
    ]) {
      expect(all, isNot(contains(host)));
      expect(all, isNot(contains('$host/')));
    }
    expect(csp['object-src'], ["'none'"]);
    expect(csp['frame-ancestors'], ["'none'"]);
  });
}
