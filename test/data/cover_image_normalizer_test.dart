// Unit + property tests for the project cover-photo normalizer.
//
// The normalizer must always emit a JPEG of exactly 1600 × 2560 px:
// wide and tall sources are center-cropped to 1.6:1 then resized; a source
// already at the cover ratio is only resized (or passed through); and bytes
// that are not a readable PNG / JPEG / WebP are rejected with a friendly
// CoverImageException.

import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:kiri_check/kiri_check.dart';
import 'package:spwrite/data/cover_image_normalizer.dart';
import 'package:test/test.dart';

/// A solid-color PNG of the given size.
Uint8List _png(int width, int height, {img.Color? color}) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: color ?? img.ColorRgb8(40, 120, 200));
  return img.encodePng(image);
}

/// Decodes [bytes] and returns the image (asserting it is a JPEG).
img.Image _decodeJpeg(Uint8List bytes) {
  expect(img.findDecoderForData(bytes), isA<img.JpegDecoder>());
  return img.decodeJpg(bytes)!;
}

void main() {
  group('normalizeCoverImageSync', () {
    test('a wide source is center-cropped and resized to 1600 × 2560', () {
      // 300 × 100: left / right thirds red, centre third green. A 1.6:1
      // centre crop (62 px wide) lies wholly inside the green band.
      final img.Image source = img.Image(width: 300, height: 100);
      img.fill(source, color: img.ColorRgb8(255, 0, 0));
      img.fillRect(source,
          x1: 100, y1: 0, x2: 199, y2: 99, color: img.ColorRgb8(0, 255, 0));

      final NormalizedCover cover =
          normalizeCoverImageSync(img.encodePng(source));
      final img.Image out = _decodeJpeg(cover.bytes);

      expect(out.width, CoverImageSpec.width);
      expect(out.height, CoverImageSpec.height);
      expect(cover.wasCropped, isTrue);
      expect(cover.sourceWidth, 300);
      expect(cover.sourceHeight, 100);
      // The kept region is the centre: the edges are green, not red.
      for (final img.Pixel p in <img.Pixel>[
        out.getPixel(5, 1280),
        out.getPixel(1594, 1280),
      ]) {
        expect(p.g, greaterThan(200));
        expect(p.r, lessThan(60));
      }
    });

    test('a tall source is center-cropped and resized to 1600 × 2560', () {
      final NormalizedCover cover = normalizeCoverImageSync(_png(100, 400));
      final img.Image out = _decodeJpeg(cover.bytes);
      expect(out.width, 1600);
      expect(out.height, 2560);
      expect(cover.wasCropped, isTrue);
    });

    test('an exact 1600 × 2560 source is kept uncropped', () {
      final NormalizedCover cover = normalizeCoverImageSync(_png(1600, 2560));
      final img.Image out = _decodeJpeg(cover.bytes);
      expect(out.width, 1600);
      expect(out.height, 2560);
      expect(cover.wasCropped, isFalse);
    });

    test('a source already at 1.6:1 is resized without cropping', () {
      final NormalizedCover cover = normalizeCoverImageSync(_png(160, 256));
      final img.Image out = _decodeJpeg(cover.bytes);
      expect(out.width, 1600);
      expect(out.height, 2560);
      expect(cover.wasCropped, isFalse);
    });

    test('a landscape JPEG source is accepted and normalized', () {
      final img.Image source = img.Image(width: 800, height: 600);
      img.fill(source, color: img.ColorRgb8(10, 10, 10));
      final NormalizedCover cover =
          normalizeCoverImageSync(img.encodeJpg(source));
      final img.Image out = _decodeJpeg(cover.bytes);
      expect(out.width, 1600);
      expect(out.height, 2560);
    });

    test('transparent PNG pixels are flattened onto white', () {
      final img.Image source =
          img.Image(width: 160, height: 256, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(0, 0, 0, 0));
      final img.Image out =
          _decodeJpeg(normalizeCoverImageSync(img.encodePng(source)).bytes);
      final img.Pixel p = out.getPixel(800, 1280);
      expect(p.r, greaterThan(240));
      expect(p.g, greaterThan(240));
      expect(p.b, greaterThan(240));
    });

    test('random / non-image bytes are rejected', () {
      expect(
        () => normalizeCoverImageSync(
            Uint8List.fromList(List<int>.generate(512, (int i) => i * 7))),
        throwsA(isA<CoverImageException>()),
      );
      expect(
        () => normalizeCoverImageSync(
            Uint8List.fromList('not an image at all'.codeUnits)),
        throwsA(isA<CoverImageException>()),
      );
    });

    test('very short garbage bytes are rejected', () {
      expect(
        () => normalizeCoverImageSync(Uint8List.fromList(<int>[1, 2, 3, 4])),
        throwsA(isA<CoverImageException>()),
      );
    });

    test('empty bytes are rejected', () {
      expect(
        () => normalizeCoverImageSync(Uint8List(0)),
        throwsA(isA<CoverImageException>()),
      );
    });

    test('a truncated PNG is rejected', () {
      final Uint8List png = _png(200, 300);
      expect(
        () => normalizeCoverImageSync(Uint8List.sublistView(png, 0, 60)),
        throwsA(isA<CoverImageException>()),
      );
    });

    test('an unsupported format (GIF) is rejected', () {
      final img.Image source = img.Image(width: 40, height: 64);
      expect(
        () => normalizeCoverImageSync(img.encodeGif(source)),
        throwsA(isA<CoverImageException>()),
      );
    });
  });

  group('normalizeCoverImage (off the UI isolate)', () {
    test('produces the same exact output size', () async {
      final NormalizedCover cover = await normalizeCoverImage(_png(500, 500));
      final img.Image out = _decodeJpeg(cover.bytes);
      expect(out.width, 1600);
      expect(out.height, 2560);
      expect(cover.wasCropped, isTrue);
    });

    test('surfaces CoverImageException across the isolate boundary', () {
      expect(
        normalizeCoverImage(Uint8List.fromList(<int>[1, 2, 3, 4])),
        throwsA(isA<CoverImageException>()),
      );
    });
  });

  // Property: for any source dimensions, the output is exactly 1600 × 2560 and
  // `wasCropped` is set exactly when the source ratio is off 1.6:1 by more
  // than a pixel of rounding.
  //
  // **Validates: cover format requirement (1600 × 2560, 1.6:1)**
  property('normalized cover is always exactly 1600 × 2560', () {
    forAll(
      combine2(integer(min: 1, max: 400), integer(min: 1, max: 400)),
      ((int, int) dims) {
        final (int w, int h) = dims;
        final NormalizedCover cover = normalizeCoverImageSync(_png(w, h));
        final img.Image out = img.decodeJpg(cover.bytes)!;
        expect(out.width, CoverImageSpec.width);
        expect(out.height, CoverImageSpec.height);

        final int expectedCropW =
            w / h > CoverImageSpec.aspectRatio
                ? (h * CoverImageSpec.aspectRatio).round().clamp(1, w)
                : w;
        final int expectedCropH =
            w / h < CoverImageSpec.aspectRatio
                ? (w / CoverImageSpec.aspectRatio).round().clamp(1, h)
                : h;
        expect(
          cover.wasCropped,
          (w - expectedCropW).abs() > 1 || (h - expectedCropH).abs() > 1,
        );
      },
      maxExamples: 8,
    );
  });
}
