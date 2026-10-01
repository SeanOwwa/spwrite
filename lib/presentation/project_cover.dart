/// Presentation layer: [ProjectCover], the portrait (1:1.6) cover thumbnail
/// shared by the Dashboard project cards, the create/edit project dialog, and
/// the workspace sidebar header.
///
/// When the project has a cover photo it is shown edge-to-edge
/// ([BoxFit.cover]); otherwise the colorful brand-gradient badge carrying the
/// project's initial is shown as the fallback. Every color comes from
/// [AppPalette] / [AppStyle].
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The placeholder shown when a project has an empty / whitespace-only name.
const String kUntitledProjectPlaceholder = 'Untitled Project';

/// Transforms a Project's stored Name into the label the UI displays, without
/// altering the stored Name.
///
/// Returns [kUntitledProjectPlaceholder] when [storedName] trims to empty
/// (empty or whitespace-only); otherwise returns [storedName] unchanged.
String projectDisplayName(String storedName) {
  if (storedName.trim().isEmpty) {
    return kUntitledProjectPlaceholder;
  }
  return storedName;
}

/// A portrait cover thumbnail: the [coverImage] when present, else the
/// gradient initial badge.
///
/// The widget fills the constraints it is given; wrap it in an [AspectRatio]
/// of [AppStyle.coverAspectRatio] (or a fixed width/height at that ratio) to
/// get the 1:1.6 book-cover shape.
class ProjectCover extends StatelessWidget {
  /// The cover photo bytes, or `null` to show the initial fallback.
  final Uint8List? coverImage;

  /// The project's stored name, used for the fallback initial and the
  /// semantic label.
  final String projectName;

  /// Corner radius of the thumbnail.
  final BorderRadius borderRadius;

  /// Font size of the fallback initial; scales with the thumbnail size.
  final double initialFontSize;

  const ProjectCover({
    super.key,
    required this.coverImage,
    required this.projectName,
    this.borderRadius = AppStyle.controlRadius,
    this.initialFontSize = 48,
  });

  /// The first letter of the display name, uppercased, or '' when none.
  String get _initial {
    final String shown = projectDisplayName(projectName).trim();
    if (shown.isEmpty) return '';
    return shown.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = coverImage;
    final String name = projectDisplayName(projectName);
    return ClipRRect(
      borderRadius: borderRadius,
      child: bytes != null
          ? Image.memory(
              bytes,
              key: const ValueKey<String>('project-cover-image'),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              semanticLabel: 'Cover of $name',
              errorBuilder: (BuildContext context, Object error, _) =>
                  _buildFallback(),
            )
          : _buildFallback(),
    );
  }

  /// The colorful brand-gradient badge with the project's initial.
  Widget _buildFallback() {
    final String initial = _initial;
    return Container(
      key: const ValueKey<String>('project-cover-fallback'),
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      decoration: const BoxDecoration(gradient: AppStyle.accent),
      child: ExcludeSemantics(
        child: initial.isEmpty
            ? Icon(
                Icons.menu_book_rounded,
                size: initialFontSize,
                color: AppPalette.onPrimary,
              )
            : Text(
                initial,
                style: TextStyle(
                  color: AppPalette.onPrimary,
                  fontSize: initialFontSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
      ),
    );
  }
}
