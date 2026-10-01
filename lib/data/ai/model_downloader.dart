/// Data layer: the one-time [ModelDownloader] that fetches the Local Model (the
/// GGUF Model Asset described by [ModelMetadata]) into the app's data directory,
/// verifies its integrity, and caches it for fully-offline use afterwards
/// (design §6, Req 3).
///
/// The Local Model is downloaded exactly once — the only moment the assistant
/// touches the network. This downloader implements the core "fetch → verify →
/// accept" flow that guarantees a partial or corrupt file is never left behind
/// as if it were a complete, ready asset (Req 3.5):
///
///   1. Stream the GGUF from [ModelMetadata.url] to a **temp file** in the app
///      data directory, computing its SHA-256 incrementally as bytes arrive and
///      reporting byte-level progress (Req 3.2).
///   2. Verify the streamed bytes against [ModelMetadata.sha256]; on mismatch,
///      delete the temp file and reject — nothing is accepted (Req 3.5).
///   3. On success, atomically rename the temp file into the final cached path
///      so a reader ever only sees a complete file (Req 3.3, 3.7).
///
/// The cached location is derived from [ModelMetadata.id] under the application
/// support directory (via `path_provider`), so it persists across app launches
/// and can later back the "already present" fast-path (Req 3.6, task 3.2).
///
/// ### Testability
/// The [http.Client] is injected (constructor arg, defaulting to a real client)
/// and the target-directory resolution is overridable ([directoryResolver]), so
/// unit tests (task 3.4) can drive the whole flow with a fake client and a temp
/// directory without ever touching `path_provider` or the network. The class is
/// structured so the "already present" fast-path/resumable download (task 3.2)
/// and offline handling (task 3.3) can be layered on without reshaping it.
library;

import 'dart:async';
import 'dart:convert' show ByteConversionSink;
import 'dart:io';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../domain/ai/model_catalog.dart';

/// Resolves the directory into which the Model Asset is cached. Injected so
/// tests can point the downloader at a temporary directory instead of the real
/// application-support directory. Returns the directory that will hold both the
/// temp file and the final cached file.
typedef ModelDirectoryResolver = Future<Directory> Function();

/// Reports download progress as bytes arrive: [received] is the number of bytes
/// written so far and [total] is the expected total (the server's
/// `Content-Length`, or the catalog's expected size when the server omits it,
/// or `null` when neither is known). Called frequently during a download, so
/// implementations should be cheap.
typedef DownloadProgressCallback = void Function(int received, int? total);

/// Raised when a download cannot be completed. Carries a human-readable
/// [message] the state/presentation layer can surface (e.g. a retry affordance,
/// Req 3.5), and an optional [cause] with the underlying error.
///
/// The [isOffline] flag distinguishes a **connectivity** failure (the device
/// has no internet, so the one-time download can't even start) from other
/// download failures (bad HTTP status, checksum mismatch, generic I/O). The
/// state/presentation layer uses this to surface the right message: an offline
/// failure explains that the initial download needs an internet connection and
/// that the app stays usable without the assistant until connectivity returns
/// (Req 3.4), while other failures offer a plain retry affordance (Req 3.5).
class ModelDownloadException implements Exception {
  /// A human-readable description of what went wrong.
  final String message;

  /// The underlying error, when this exception wraps another failure.
  final Object? cause;

  /// Whether this failure was caused by a lack of internet connectivity (as
  /// opposed to a server error, integrity mismatch, or other I/O failure). When
  /// `true`, the presentation layer should explain that the one-time download
  /// requires an internet connection rather than offer a plain retry (Req 3.4).
  final bool isOffline;

  const ModelDownloadException(
    this.message, [
    this.cause,
  ]) : isOffline = false;

  /// A connectivity failure: the download couldn't reach the network. Sets
  /// [isOffline] so callers can surface the "needs an internet connection"
  /// message (Req 3.4). [message] defaults to a clear, user-facing explanation.
  const ModelDownloadException.offline([
    this.message =
        'The one-time model download requires an internet connection. '
        'Connect to the internet and try again; the app remains usable '
        'without the assistant until then.',
    this.cause,
  ]) : isOffline = true;

  @override
  String toString() => cause == null
      ? 'ModelDownloadException: $message'
      : 'ModelDownloadException: $message ($cause)';
}

/// Downloads, verifies, and caches the Local Model (GGUF Model Asset).
///
/// A single instance can download any [ModelMetadata]; it holds no per-download
/// state beyond its injected collaborators, so it is safe to construct once and
/// reuse. The core entry point is [download]; [resolveCachedPath] exposes where
/// a given model is (or will be) cached so callers can implement the
/// "already present" fast-path (task 3.2).
class ModelDownloader {
  /// Suffix for the in-progress temp file. The download writes here and only
  /// renames to the final name after the checksum verifies, so a reader never
  /// observes a partial file under the final path (Req 3.5).
  static const String _tempSuffix = '.part';

  /// File extension for the cached GGUF asset.
  static const String _modelExtension = '.gguf';

  /// Small fixed tolerance (on top of a 5% proportional margin) allowed over the
  /// catalog's expected size before a download is considered over-large and
  /// aborted — absorbs minor repackaging differences without letting a hostile
  /// mirror stream unbounded data.
  static const int _sizeMarginBytes = 64 * 1024; // 64 KB

  /// Absolute ceiling used only when the catalog's expected size is unknown, so
  /// an unbounded body can never exhaust the disk.
  static const int _absoluteMaxBytes = 8 * 1000 * 1000 * 1000; // 8 GB

  /// The HTTP client used to stream the download. Injected for testability;
  /// defaults to a real [http.Client]. When the caller passes its own client it
  /// owns that client's lifecycle; the default client is closed by [close].
  final http.Client _client;

  /// Whether [_client] was created internally (and so should be closed by
  /// [close]) or supplied by the caller (and so is the caller's to close).
  final bool _ownsClient;

  /// Resolves the directory the asset is cached in. Defaults to
  /// `path_provider`'s application-support directory, which is a per-platform
  /// writable location that persists across launches (Req 3.7). Overridable so
  /// tests avoid `path_provider`.
  final ModelDirectoryResolver _directoryResolver;

  /// Creates a downloader.
  ///
  /// [client] defaults to a real [http.Client] (created and owned internally,
  /// closed by [close]); pass a fake in tests. [directoryResolver] defaults to
  /// the application-support directory; override it in tests to target a temp
  /// directory.
  ModelDownloader({
    http.Client? client,
    ModelDirectoryResolver? directoryResolver,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _directoryResolver =
            directoryResolver ?? _defaultDirectoryResolver;

  /// The default directory resolver: the application-support directory, a
  /// per-platform writable location that persists across app launches (Req 3.7).
  static Future<Directory> _defaultDirectoryResolver() {
    return getApplicationSupportDirectory();
  }

  /// The absolute path at which [model] is (or will be) cached, without
  /// touching the network. Derived from [ModelMetadata.id] under the resolved
  /// directory, so it is stable across launches (Req 3.6, 3.7) and usable by an
  /// "already present" fast-path (task 3.2).
  Future<String> resolveCachedPath(ModelMetadata model) async {
    final Directory dir = await _directoryResolver();
    return _cachedFile(dir, model).path;
  }

  /// Whether [model] is already cached on disk and ready to load, without any
  /// network access (Req 3.6).
  ///
  /// A cached file is considered present when the final `<id>.gguf` file exists
  /// under the resolved directory (which persists across launches, Req 3.6/3.7).
  /// The final file only ever appears via the atomic rename in [download] that
  /// happens **after** the sha256 verification, so its mere presence already
  /// implies a previously-verified asset. We therefore trust presence here and
  /// do **not** re-hash the (potentially ~1 GB) file on every check — re-hashing
  /// on each launch would be slow and defeats the offline fast-path. Integrity
  /// is (re-)established whenever the file is (re-)produced by [download].
  Future<bool> isModelPresent(ModelMetadata model) async {
    return await cachedModelPathIfPresent(model) != null;
  }

  /// The absolute path of the cached [model] if it is already present on disk,
  /// or `null` when it is not — never touches the network (Req 3.6).
  ///
  /// Callers use this for the "already present" fast-path: a non-null result
  /// means the assistant can start fully offline. See [isModelPresent] for why
  /// presence is trusted rather than re-verified here.
  Future<String?> cachedModelPathIfPresent(ModelMetadata model) async {
    final Directory dir = await _directoryResolver();
    final File cachedFile = _cachedFile(dir, model);
    return await cachedFile.exists() ? cachedFile.path : null;
  }

  /// Downloads [model], verifies its SHA-256, and atomically moves it into the
  /// cache, returning the absolute path of the cached file (Req 3.2, 3.3, 3.5,
  /// 3.6, 3.7).
  ///
  /// ### "Already present" fast-path (Req 3.6)
  /// If the final cached file already exists on disk, [download] returns its
  /// path immediately **without any network access** — the asset only ever
  /// reaches the final path via the verified atomic rename below, so presence
  /// implies a previously-verified file (see [isModelPresent]).
  ///
  /// ### Fetch → verify → accept
  /// Otherwise it streams the response body to a temp file (`<id>.gguf.part`)
  /// and reports progress via [onProgress]. If the server responds with a
  /// non-success status, the computed checksum does not match
  /// [ModelMetadata.sha256], or any I/O fails, the temp file is removed and a
  /// [ModelDownloadException] is thrown — a corrupt or partial asset is never
  /// accepted (Req 3.5). On success the temp file is renamed onto the final
  /// path, an atomic operation within the same directory, so a reader only ever
  /// sees a complete file (Req 3.3).
  ///
  /// ### Offline handling (Req 3.4)
  /// When the attempt fails because the device has no connectivity — the socket
  /// layer can't reach the host (host-lookup failure, connection refused/reset,
  /// network unreachable) — the thrown [ModelDownloadException] has
  /// [ModelDownloadException.isOffline] set, with a message explaining that the
  /// one-time download needs an internet connection. This is distinct from a bad
  /// HTTP status or a checksum mismatch (both non-offline) so the state /
  /// presentation layer can word the two differently and keep the app usable
  /// without the assistant until connectivity returns. As with any failure, the
  /// `.part` temp file is removed first, so no partial asset is left behind.
  ///
  /// ### Resumable / safely re-runnable (Req 3.7)
  /// This is always safe to re-run after an interruption. When a leftover
  /// `.part` from a previous attempt is present, it attempts an HTTP **Range**
  /// resume: it sends `Range: bytes=<existing>-` and appends the returned bytes
  /// on a `206 Partial Content`. If the server ignores the range and replies
  /// `200 OK` (a full body), the temp file is truncated and the download starts
  /// fresh. Either way the sha256 is computed over the **full assembled file**
  /// (the file is re-hashed from disk after the transfer, since an incremental
  /// hash cannot resume mid-stream), so a resumed download is verified exactly
  /// like a fresh one before it is accepted.
  Future<String> download(
    ModelMetadata model, {
    DownloadProgressCallback? onProgress,
  }) async {
    final Directory dir = await _directoryResolver();
    await dir.create(recursive: true);

    final File cachedFile = _cachedFile(dir, model);
    final File tempFile = _tempFile(dir, model);

    // "Already present" fast-path: a verified asset already sits at the final
    // path (it only ever gets there via the atomic rename after verification),
    // so return it immediately without touching the network (Req 3.6).
    if (await cachedFile.exists()) {
      onProgress?.call(await cachedFile.length(), await cachedFile.length());
      return cachedFile.path;
    }

    // Determine how much of a prior attempt we can resume from. A leftover
    // `.part` is handled cleanly: we try to continue it via a Range request
    // rather than discarding progress, but always fall back to a clean restart
    // if resuming isn't possible (Req 3.7).
    int existingBytes = 0;
    if (await tempFile.exists()) {
      try {
        existingBytes = await tempFile.length();
      } catch (_) {
        existingBytes = 0;
      }
    }

    IOSink? sink;
    try {
      final http.Request request = http.Request('GET', Uri.parse(model.url));
      if (existingBytes > 0) {
        // Ask the server to continue from where the leftover `.part` ended.
        request.headers['Range'] = 'bytes=$existingBytes-';
      }

      final http.StreamedResponse response = await _client.send(request);

      final bool resuming =
          existingBytes > 0 && response.statusCode == HttpStatus.partialContent;

      if (response.statusCode == HttpStatus.ok) {
        // Server sent the full body (Range ignored, or no resume requested):
        // start the temp file from scratch so we never append onto stale bytes.
        existingBytes = 0;
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } else if (!resuming) {
        // Neither a fresh 200 nor an accepted 206 resume: a real failure.
        throw ModelDownloadException(
          'Download failed with HTTP status ${response.statusCode}.',
        );
      }

      // Total expected size: for a 206 the body only covers the remaining
      // bytes, so add what we already have. Fall back to the catalog's expected
      // size when the server omits Content-Length.
      final int? bodyLength = response.contentLength;
      final int? total = bodyLength != null
          ? bodyLength + existingBytes
          : _positiveOrNull(model.sizeBytes);

      // Append when resuming, otherwise (over)write from the beginning.
      sink = tempFile.openWrite(
        mode: resuming ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      int received = existingBytes;

      // Report an initial received/total so listeners can render a determinate
      // bar (reflecting any already-downloaded bytes) before the first chunk.
      onProgress?.call(received, total);

      // Bound how many bytes we will accept so a compromised or misconfigured
      // mirror cannot stream unbounded data to disk before the sha256 check
      // ever runs (disk-exhaustion guard). The ceiling is the catalog's
      // expected size plus a tolerance margin for legitimate quantization /
      // repackaging differences; if the expected size is unknown we fall back
      // to a generous absolute cap. Exceeding it aborts the transfer, and the
      // catch below removes the partial `.part` so nothing is left behind.
      final int expected = model.sizeBytes;
      final int maxAllowed = expected > 0
          ? expected + (expected ~/ 20) + _sizeMarginBytes
          : _absoluteMaxBytes;

      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (received > maxAllowed) {
          throw ModelDownloadException(
            'Download exceeded the expected model size '
            '(received $received bytes, limit $maxAllowed). Aborting to '
            'protect disk space.',
          );
        }
        onProgress?.call(received, total);
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Hash the full assembled file from disk. Resuming means we never held a
      // running hash over the earlier bytes, so we (re-)hash the complete file;
      // this also verifies a fresh download identically (Req 3.5, 3.7).
      final String actualDigest = await _hashFile(tempFile);
      final String expectedDigest = model.sha256.toLowerCase();
      if (actualDigest != expectedDigest) {
        throw ModelDownloadException(
          'Downloaded model failed integrity check: expected sha256 '
          '$expectedDigest but got $actualDigest.',
        );
      }

      // Verified: atomically move the temp file onto the final cached path.
      // Rename within the same directory is atomic on the target filesystems,
      // so a reader only ever sees a complete file (Req 3.3, 3.5).
      if (await cachedFile.exists()) {
        await cachedFile.delete();
      }
      await tempFile.rename(cachedFile.path);
      return cachedFile.path;
    } on ModelDownloadException {
      await _closeSinkQuietly(sink);
      await _deleteQuietly(tempFile);
      rethrow;
    } catch (error) {
      // Network / I/O failure: never leave a partial asset behind (Req 3.5).
      // The `.part` is removed, so the next call to download() starts clean;
      // it remains safely re-runnable either way (Req 3.7).
      await _closeSinkQuietly(sink);
      await _deleteQuietly(tempFile);

      // Distinguish a lack of connectivity from other failures so the messaging
      // can differ: offline gets the "needs an internet connection" wording and
      // leaves the app usable without the assistant (Req 3.4); everything else
      // gets a plain retry affordance (Req 3.5). Either way, no partial asset
      // remains — the cleanup above already ran.
      if (_isConnectivityError(error)) {
        throw ModelDownloadException.offline(
          'The one-time model download requires an internet connection. '
          'Connect to the internet and try again; the app remains usable '
          'without the assistant until then.',
          error,
        );
      }

      throw ModelDownloadException(
        'Model download did not complete. Please retry.',
        error,
      );
    }
  }

  /// Whether [error] indicates a lack of internet connectivity (the download
  /// couldn't reach the host) rather than a server-side or I/O failure.
  ///
  /// Connectivity failures surface from the socket layer: a [SocketException]
  /// (DNS/host lookup failure, connection refused, connection reset, network
  /// unreachable) is the definitive signal. `package:http` wraps such failures
  /// in a [http.ClientException] whose message still originates from the socket,
  /// and some platforms throw a bare [HandshakeException] for the same
  /// underlying cause, so we detect those too. This is a best-effort
  /// classification used only to choose the message; a misclassified error still
  /// results in a clean failure with no partial asset (Req 3.4/3.5).
  static bool _isConnectivityError(Object error) {
    if (error is SocketException || error is HandshakeException) {
      return true;
    }
    if (error is http.ClientException) {
      // http surfaces connection-level failures (host lookup, connection
      // refused/reset) through ClientException; treat those as offline.
      final String message = error.message.toLowerCase();
      return message.contains('failed host lookup') ||
          message.contains('connection refused') ||
          message.contains('connection closed') ||
          message.contains('connection reset') ||
          message.contains('connection terminated') ||
          message.contains('network is unreachable') ||
          message.contains('no address associated') ||
          message.contains('socketexception');
    }
    return false;
  }

  /// The final cached file for [model] under [dir]: `<dir>/<id>.gguf`.
  File _cachedFile(Directory dir, ModelMetadata model) {
    return File(_join(dir.path, '${model.id}$_modelExtension'));
  }

  /// The in-progress temp file for [model] under [dir]: `<dir>/<id>.gguf.part`.
  File _tempFile(Directory dir, ModelMetadata model) {
    return File(_join(dir.path, '${model.id}$_modelExtension$_tempSuffix'));
  }

  /// Joins a directory and a file name with the platform separator, avoiding a
  /// duplicate separator when [dir] already ends with one (mirrors the join in
  /// `db_path_io.dart`).
  String _join(String dir, String name) {
    final String sep = Platform.pathSeparator;
    if (dir.isEmpty) return name;
    return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
  }

  /// Returns [value] when positive, else `null` — used so a missing/zero
  /// expected size does not present a bogus progress denominator.
  int? _positiveOrNull(int value) => value > 0 ? value : null;

  /// Computes the lowercase hex SHA-256 of [file] by streaming it from disk.
  ///
  /// Used to verify the fully-assembled temp file after the transfer completes.
  /// Hashing the file (rather than the network stream) is what makes a resumed
  /// download verifiable: the earlier bytes were written on a previous run and
  /// never passed through an in-memory hash, so the whole file is hashed here
  /// exactly once before it is accepted (Req 3.5, 3.7).
  Future<String> _hashFile(File file) async {
    final _HashingSink hasher = _HashingSink();
    await for (final List<int> chunk in file.openRead()) {
      hasher.add(chunk);
    }
    return hasher.digestHex();
  }

  /// Closes [sink] swallowing any error — used on the failure path where the
  /// original error is what matters.
  Future<void> _closeSinkQuietly(IOSink? sink) async {
    if (sink == null) return;
    try {
      await sink.close();
    } catch (_) {
      // Best-effort cleanup; the originating error is rethrown by the caller.
    }
  }

  /// Deletes [file] if present, swallowing any error — best-effort cleanup so a
  /// failed download leaves no partial asset (Req 3.5).
  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  /// Releases resources. Closes the internally-created HTTP client; a
  /// caller-supplied client is left open for the caller to close.
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// Accumulates bytes and computes their SHA-256 incrementally, so the large
/// asset can be hashed chunk-by-chunk (from the assembled temp file) without
/// holding the whole file in memory.
///
/// Wraps `package:crypto`'s chunked-conversion API: bytes are pushed in as they
/// arrive and the final lowercase hex digest is read once the stream completes.
class _HashingSink {
  final List<Digest> _digests = <Digest>[];
  late final ByteConversionSink _input =
      sha256.startChunkedConversion(_DigestCollector(_digests));

  /// Feeds a [chunk] of downloaded bytes into the running hash.
  void add(List<int> chunk) => _input.add(chunk);

  /// Finalizes the hash and returns its lowercase hex digest.
  String digestHex() {
    _input.close();
    return _digests.single.toString();
  }
}

/// One-shot sink that captures the final [Digest] emitted by the chunked SHA-256
/// conversion into [_target].
class _DigestCollector implements Sink<Digest> {
  final List<Digest> _target;

  _DigestCollector(this._target);

  @override
  void add(Digest data) => _target.add(data);

  @override
  void close() {}
}
