/// Data layer: normalizes a user-chosen picture into a project cover photo.
///
/// Every cover is stored at exactly [CoverImageSpec.width] ×
/// [CoverImageSpec.height] (1600 × 2560 px, a portrait book cover with a 1.6:1
/// height:width ratio). [normalizeCoverImage] decodes the source bytes (PNG,
/// JPEG, or WebP), applies any EXIF orientation, center-crops to the cover
/// aspect ratio when the source differs, resizes to the exact target size,
/// flattens transparency onto white, and re-encodes as JPEG so the stored BLOB
/// stays a sane size.
///
/// Decoding and resampling a multi-megapixel photo is CPU heavy, so the public
/// async entry point runs the work off the UI isolate via [compute] (which
/// falls back to the current isolate on web). [normalizeCoverImageSync] is the
/// pure function both use, exposed for tests.
library;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// The fixed cover-photo format.
class CoverImageSpec {
  const CoverImageSpec._();

  /// Output width in pixels.
  static const int width = 1600;

  /// Output height in pixels.
  static const int height = 2560;

  /// Width ÷ height of the cover (0.625, i.e. a 1.6:1 height:width ratio).
  static const double aspectRatio = width / height;

  /// JPEG encode quality for the stored cover.
  static const int jpegQuality = 85;

  /// The largest source side accepted, guarding against decoding an absurdly
  /// large image into memory.
  static const int maxSourceSide = 12000;

  /// The file extensions the picker offers.
  static const List<String> extensions = <String>['png', 'jpg', 'jpeg', 'webp'];

  /// The guidance shown next to the cover picker.
  static const String recommendation = 'Recommended: 1600 × 2560 px (1.6:1)';
}

/// The result of normalizing a cover photo.
@immutable
class NormalizedCover {
  /// The JPEG-encoded cover, exactly [CoverImageSpec.width] ×
  /// [CoverImageSpec.height].
  final Uint8List bytes;

  /// The decoded source dimensions (after EXIF orientation).
  final int sourceWidth;
  final int sourceHeight;

  /// Whether the source aspect ratio differed and it was center-cropped.
  final bool wasCropped;

  const NormalizedCover({
    required this.bytes,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.wasCropped,
  });
}

/// Thrown when the bytes cannot be turned into a cover (not an image, an
/// unsupported format, corrupt data, or an oversized source). [message] is
/// written for the user and can be shown inline as-is.
class CoverImageException implements Exception {
  final String message;

  const CoverImageException(this.message);

  @override
  String toString() => 'CoverImageException: $message';
}

/// Normalizes [source] into a cover photo off the UI isolate.
///
/// Throws [CoverImageException] when the bytes are not a readable PNG, JPEG, or
/// WebP image.
Future<NormalizedCover> normalizeCoverImage(Uint8List source) {
  return compute(normalizeCoverImageSync, source,
      debugLabel: 'normalizeCoverImage');
}

/// The synchronous normalization behind [normalizeCoverImage].
NormalizedCover normalizeCoverImageSync(Uint8List source) {
  if (source.isEmpty) {
    throw const CoverImageException('That file is empty.');
  }

  // Format sniffing can itself throw on very short / garbage input, so treat
  // any failure here as "not a supported image".
  img.Decoder? found;
  try {
    found = img.findDecoderForData(source);
  } catch (_) {
    found = null;
  }
  if (found == null ||
      (found is! img.PngDecoder &&
          found is! img.JpegDecoder &&
          found is! img.WebPDecoder)) {
    throw const CoverImageException(
      'That file isn\'t a supported image. Choose a PNG, JPG, or WebP file.',
    );
  }

  final img.Decoder decoder = found;
  img.Image? decoded;
  try {
    // Check the header dimensions before allocating the full bitmap.
    final img.DecodeInfo? info = decoder.startDecode(source);
    if (info != null &&
        (info.width > CoverImageSpec.maxSourceSide ||
            info.height > CoverImageSpec.maxSourceSide)) {
      throw const CoverImageException(
        'That image is too large. Use one under 12,000 px on each side.',
      );
    }
    decoded = decoder.decode(source);
  } on CoverImageException {
    rethrow;
  } catch (_) {
    decoded = null;
  }
  if (decoded == null || decoded.width == 0 || decoded.height == 0) {
    throw const CoverImageException(
      'That image couldn\'t be read. It may be damaged.',
    );
  }

  // Apply EXIF orientation so phone photos are not stored sideways.
  final img.Image oriented = img.bakeOrientation(decoded);
  final int w = oriented.width;
  final int h = oriented.height;

  // Center-crop to the cover aspect ratio when the source differs by more
  // than a pixel of rounding.
  int cropW = w;
  int cropH = h;
  if (w / h > CoverImageSpec.aspectRatio) {
    cropW = (h * CoverImageSpec.aspectRatio).round().clamp(1, w);
  } else if (w / h < CoverImageSpec.aspectRatio) {
    cropH = (w / CoverImageSpec.aspectRatio).round().clamp(1, h);
  }
  final bool wasCropped = (w - cropW).abs() > 1 || (h - cropH).abs() > 1;

  img.Image working = oriented;
  if (wasCropped) {
    working = img.copyCrop(
      oriented,
      x: (w - cropW) ~/ 2,
      y: (h - cropH) ~/ 2,
      width: cropW,
      height: cropH,
    );
  }

  if (working.width != CoverImageSpec.width ||
      working.height != CoverImageSpec.height) {
    final bool downscale = working.width > CoverImageSpec.width;
    working = img.copyResize(
      working,
      width: CoverImageSpec.width,
      height: CoverImageSpec.height,
      interpolation:
          downscale ? img.Interpolation.average : img.Interpolation.cubic,
    );
  }

  // JPEG has no alpha: flatten transparent pixels onto white rather than
  // letting them turn black.
  if (working.hasAlpha) {
    final img.Image flat = img.Image(
      width: working.width,
      height: working.height,
      numChannels: 3,
    );
    img.fill(flat, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, working);
    working = flat;
  }

  final Uint8List encoded =
      img.encodeJpg(working, quality: CoverImageSpec.jpegQuality);

  return NormalizedCover(
    bytes: encoded,
    sourceWidth: w,
    sourceHeight: h,
    wasCropped: wasCropped,
  );
}
