// Unit tests for the one-time ModelDownloader (task 3.4).
//
// Validates: Requirements 3.4, 3.5
//
// These tests drive ModelDownloader end-to-end with a fake http.Client and a
// temp directory (via the injected directoryResolver), so the whole
// fetch → verify → accept flow runs without touching path_provider or the
// network. The four behaviors under test (mirroring task 3.4):
//
//   1. Success: bytes whose sha256 matches ModelMetadata.sha256 are streamed,
//      verified, and atomically moved to the final `<id>.gguf` path. The final
//      file contents equal the bytes, no `.part` is left behind, and progress
//      callbacks fire (received grows up to total) (Req 3.5).
//   2. Corrupt: bytes whose sha256 does NOT match are rejected — download()
//      throws a non-offline ModelDownloadException, no final file is created,
//      and no `.part` remains (Req 3.5).
//   3. Offline: a client that throws SocketException on send causes download()
//      to throw a ModelDownloadException with isOffline == true and a message
//      about needing an internet connection; no partial asset remains (Req 3.4).
//   4. Already-present fast-path: when `<id>.gguf` already exists, download()
//      returns immediately without invoking the client, and isModelPresent is
//      true (Req 3.5/3.6).
//
// The fake clients only implement send(); every other http.Client method throws
// UnimplementedError so an accidental dependency surfaces loudly.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:spwrite/data/ai/model_downloader.dart';
import 'package:spwrite/domain/ai/model_catalog.dart';

// ---------------------------------------------------------------------------
// Fake http.Client that returns a canned streamed body for send().
//
// The downloader uses client.send(Request) (a streamed request), so the fake
// only needs to implement send(); it records how many times it was called so a
// test can assert the fast-path never touched the client. Every other method
// throws so an unexpected dependency is loud.
// ---------------------------------------------------------------------------
class _FakeStreamingClient extends http.BaseClient {
  _FakeStreamingClient(this.bodyBytes);

  final List<int> bodyBytes;

  /// Number of times send() was invoked — used to prove the fast-path never
  /// reaches the network.
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount += 1;
    final Stream<List<int>> stream =
        Stream<List<int>>.fromIterable(<List<int>>[bodyBytes]);
    return http.StreamedResponse(
      stream,
      200,
      contentLength: bodyBytes.length,
      request: request,
    );
  }
}

/// Fake client whose send() throws a SocketException, simulating a device with
/// no connectivity (host lookup failure). The downloader classifies this as an
/// offline failure (Req 3.4).
class _OfflineClient extends http.BaseClient {
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount += 1;
    throw const SocketException(
      'Failed host lookup: example.invalid',
    );
  }
}

/// Fake client that fails the test if send() is ever called — used to prove the
/// already-present fast-path performs no network access (Req 3.6).
class _NeverCalledClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    fail('ModelDownloader must not touch the network on the fast-path.');
  }
}

/// Fake client that streams far more bytes than the model's expected size,
/// with no Content-Length, to exercise the download size cap (a hostile /
/// misconfigured mirror). Emits many small chunks so the cap trips mid-stream.
class _OversizedClient extends http.BaseClient {
  _OversizedClient({required this.chunkSize, required this.chunkCount});

  final int chunkSize;
  final int chunkCount;
  int sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount += 1;
    Stream<List<int>> body() async* {
      for (int i = 0; i < chunkCount; i++) {
        yield List<int>.filled(chunkSize, 0x41);
      }
    }

    // No contentLength: the server "omits" the size, so the cap must fall back
    // to bounding by the catalog's expected size (+ margin).
    return http.StreamedResponse(body(), 200, request: request);
  }
}

void main() {
  late Directory tempDir;
  late ModelDirectoryResolver resolver;

  // A small deterministic byte payload standing in for the (much larger) GGUF.
  final Uint8List modelBytes =
      Uint8List.fromList(utf8.encode('the-local-model-gguf-bytes'));
  final String modelSha256 = sha256.convert(modelBytes).toString();

  // ModelMetadata whose sha256 matches the payload above, so the success path
  // verifies. The url is never actually fetched (the client is faked).
  final ModelMetadata model = ModelMetadata(
    id: 'test-model-q4',
    url: 'https://example.invalid/test-model-q4.gguf',
    sizeBytes: modelBytes.length,
    sha256: modelSha256,
    licenseName: 'Apache-2.0',
    licenseUrl: 'https://example.invalid/license',
  );

  String cachedPath() => '${tempDir.path}${Platform.pathSeparator}'
      '${model.id}.gguf';
  String partPath() => '${cachedPath()}.part';

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('model_downloader_test');
    resolver = () async => tempDir;
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('concurrent downloads of one model share a single transfer', () async {
    final _FakeStreamingClient client = _FakeStreamingClient(modelBytes);
    final ModelDownloader downloader = ModelDownloader(
      client: client,
      directoryResolver: resolver,
    );
    addTearDown(downloader.close);

    int secondProgress = 0;
    final Future<String> first = downloader.download(model);
    final Future<String> second = downloader.download(
      model,
      onProgress: (int received, int? total) => secondProgress++,
    );
    expect(identical(first, second), isTrue);
    final List<String> paths = await Future.wait(<Future<String>>[first, second]);
    expect(paths.toSet(), <String>{cachedPath()});
    expect(await File(cachedPath()).readAsBytes(), equals(modelBytes));
    expect(secondProgress, greaterThan(0));
  });

  test(
    'success: verifies, caches at <id>.gguf, leaves no .part, reports progress',
    () async {
      final _FakeStreamingClient client = _FakeStreamingClient(modelBytes);
      final ModelDownloader downloader = ModelDownloader(
        client: client,
        directoryResolver: resolver,
      );
      addTearDown(downloader.close);

      final List<(int, int?)> progress = <(int, int?)>[];
      final String returnedPath = await downloader.download(
        model,
        onProgress: (int received, int? total) =>
            progress.add((received, total)),
      );

      // The returned path is the final cached file, which exists.
      expect(returnedPath, equals(cachedPath()));
      final File cached = File(returnedPath);
      expect(await cached.exists(), isTrue);

      // Its contents equal the streamed bytes exactly.
      expect(await cached.readAsBytes(), equals(modelBytes));

      // No `.part` temp file is left behind after a successful download.
      expect(await File(partPath()).exists(), isFalse);

      // Progress fired and grew up to the total (which equals the byte count).
      expect(progress, isNotEmpty);
      final int lastReceived = progress.last.$1;
      expect(lastReceived, equals(modelBytes.length));
      expect(progress.last.$2, equals(modelBytes.length));
      // Received is monotonically non-decreasing and ends at the total.
      for (int i = 1; i < progress.length; i++) {
        expect(progress[i].$1, greaterThanOrEqualTo(progress[i - 1].$1));
      }
      expect(client.sendCount, equals(1));
    },
  );

  test(
    'corrupt: sha256 mismatch is rejected (non-offline), no file or .part left',
    () async {
      // Bytes whose sha256 will NOT match model.sha256.
      final Uint8List corruptBytes =
          Uint8List.fromList(utf8.encode('totally-different-bytes'));
      final _FakeStreamingClient client = _FakeStreamingClient(corruptBytes);
      final ModelDownloader downloader = ModelDownloader(
        client: client,
        directoryResolver: resolver,
      );
      addTearDown(downloader.close);

      await expectLater(
        downloader.download(model),
        throwsA(
          isA<ModelDownloadException>()
              .having((ModelDownloadException e) => e.isOffline, 'isOffline',
                  isFalse),
        ),
      );

      // A corrupt/partial asset is never accepted: neither the final file nor
      // the `.part` remains (Req 3.5).
      expect(await File(cachedPath()).exists(), isFalse);
      expect(await File(partPath()).exists(), isFalse);
    },
  );

  test(
    'offline: SocketException surfaces as an offline exception, no partial left',
    () async {
      final _OfflineClient client = _OfflineClient();
      final ModelDownloader downloader = ModelDownloader(
        client: client,
        directoryResolver: resolver,
      );
      addTearDown(downloader.close);

      await expectLater(
        downloader.download(model),
        throwsA(
          isA<ModelDownloadException>()
              .having((ModelDownloadException e) => e.isOffline, 'isOffline',
                  isTrue)
              .having(
                (ModelDownloadException e) => e.message.toLowerCase(),
                'message',
                contains('internet connection'),
              ),
        ),
      );

      expect(client.sendCount, equals(1));
      // No partial asset remains after an offline failure (Req 3.4/3.5).
      expect(await File(cachedPath()).exists(), isFalse);
      expect(await File(partPath()).exists(), isFalse);
    },
  );

  test(
    'already-present fast-path: returns cached path without touching network',
    () async {
      // Pre-create the final cached file so the fast-path triggers.
      final File cached = File(cachedPath());
      await cached.writeAsBytes(modelBytes);

      final _NeverCalledClient client = _NeverCalledClient();
      final ModelDownloader downloader = ModelDownloader(
        client: client,
        directoryResolver: resolver,
      );
      addTearDown(downloader.close);

      // isModelPresent reflects the on-disk cached file, no network.
      expect(await downloader.isModelPresent(model), isTrue);
      expect(await downloader.cachedModelPathIfPresent(model),
          equals(cachedPath()));

      // download() returns immediately; _NeverCalledClient.send would fail the
      // test if the network were touched.
      final String returnedPath = await downloader.download(model);
      expect(returnedPath, equals(cachedPath()));
      // The pre-existing file is untouched.
      expect(await cached.readAsBytes(), equals(modelBytes));
    },
  );

  test(
    'oversized body: aborts once the size cap is exceeded, leaves no .part '
    'or final file (disk-exhaustion guard)',
    () async {
      // Stream ~200 KB in 20 KB chunks against a model whose expected size is
      // only 26 bytes, so the cap (expected + 5% + 64 KB margin) is exceeded
      // partway through and the transfer is aborted.
      final _OversizedClient client =
          _OversizedClient(chunkSize: 20 * 1024, chunkCount: 10);
      final ModelDownloader downloader = ModelDownloader(
        client: client,
        directoryResolver: resolver,
      );
      addTearDown(downloader.close);

      await expectLater(
        downloader.download(model),
        throwsA(
          isA<ModelDownloadException>().having(
            (ModelDownloadException e) => e.message.toLowerCase(),
            'message',
            contains('exceeded'),
          ),
        ),
      );

      // No partial or final asset is left behind after the abort (Req 3.5).
      expect(await File(cachedPath()).exists(), isFalse);
      expect(await File(partPath()).exists(), isFalse);
    },
  );
}
