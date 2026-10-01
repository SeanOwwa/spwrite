/// Domain layer: the [ConnectivityStatus] value and the [ConnectivityProbe]
/// abstraction over "does the device currently have internet connectivity?"
/// (design §7, Req 4).
///
/// Connectivity is surfaced to the AI Panel as a **UI hint only** (Req 4.4): the
/// panel shows a non-blocking "you're offline — internet search is unavailable"
/// banner when offline (Req 4.2), while chat and Project-Context search stay
/// fully functional offline (Req 4.3). A wrong result (e.g. a captive network)
/// therefore never blocks an offline-capable feature — the probe drives a hint,
/// nothing more.
///
/// The state layer (`AiAssistantState`) depends only on this interface, never on
/// the concrete network check, exactly as it depends on [LlmEngine] and
/// [ContextRetriever] rather than their data-layer implementations. That keeps
/// the state layer unit-testable: task 4.2 substitutes a fake probe and drives
/// [ConnectivityStatus] transitions without any real network. The data layer's
/// `NetworkConnectivityProbe` implements this over `dart:io`.
///
/// The probe is exposed as a [ValueListenable] so a `ChangeNotifier` in the
/// state layer can simply add a listener and mirror the current [value] into its
/// own observable field, updating live as connectivity changes (Req 4.5) — the
/// same `flutter/foundation` listenable vocabulary the rest of the state layer
/// already speaks.
library;

import 'package:flutter/foundation.dart';

/// Whether the device currently has internet connectivity, as understood by the
/// [ConnectivityProbe] (Req 4.1).
///
/// This is a **hint**, not a guarantee: it drives the AI Panel's offline banner
/// (Req 4.2) and nothing else. Offline-capable features (chat, Project-Context
/// search) must keep working regardless of this value, so a misclassification
/// degrades gracefully rather than blocking anything (Req 4.4).
enum ConnectivityStatus {
  /// The device appears to have working internet connectivity.
  online,

  /// The device appears to have no internet connectivity — the AI Panel shows
  /// its non-blocking offline hint (Req 4.2).
  offline,

  /// Connectivity has not been determined yet (before the first check completes)
  /// or the latest check was inconclusive. Treated as "not known to be offline":
  /// the panel does not assert either state, and offline-capable features stay
  /// available (Req 4.4).
  unknown,
}

/// Abstracts live connectivity detection so the state layer never touches the
/// concrete network check (Req 4.1).
///
/// Implementations expose the current [ConnectivityStatus] via [ValueListenable]
/// and update it as connectivity changes (Req 4.5). Detection is a best-effort,
/// tolerant signal used only for a UI hint (Req 4.4); it must never throw or
/// block from a listener's perspective — a failed check simply reports
/// [ConnectivityStatus.offline] or [ConnectivityStatus.unknown].
///
/// Lifecycle: callers [start] the probe to begin checking (and optionally run an
/// immediate first check), and [dispose] it to stop any periodic checking and
/// release listeners so no timer outlives the owning state.
abstract class ConnectivityProbe implements ValueListenable<ConnectivityStatus> {
  /// The most recently determined connectivity status. Starts at
  /// [ConnectivityStatus.unknown] until the first check completes.
  @override
  ConnectivityStatus get value;

  /// Begins connectivity detection: performs an initial check and, for periodic
  /// implementations, starts the recurring checks that keep [value] current as
  /// connectivity changes (Req 4.5). Calling [start] when already started is a
  /// no-op. Returns once startup work is scheduled (it does not block on the
  /// first check).
  void start();

  /// Stops any periodic checking, removes registered listeners, and releases
  /// resources (e.g. cancels the recurring timer) so nothing outlives the owner
  /// (Req 4.5). After [dispose] the probe must not be reused.
  void dispose();
}
