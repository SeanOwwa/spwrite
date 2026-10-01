/// Web export helpers: the web build keeps its browser download, so there is
/// no Save As flow and no "Show in folder". Selected via the conditional import
/// in `export_dialog.dart`.
library;

import '../../domain/app_settings_repository.dart';
import 'export_location_service.dart';

/// The native Save As export flow is not used on web.
bool get supportsExportLocation => false;

/// Never called on web ([supportsExportLocation] is `false`).
ExportLocationService createExportLocationService(
  AppSettingsRepository settings,
) {
  throw UnsupportedError('Export locations are not supported on web.');
}

/// No-op on web.
Future<void> revealInFolder(String filePath) async {}
