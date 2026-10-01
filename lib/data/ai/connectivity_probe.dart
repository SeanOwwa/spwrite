/// Data layer: [NetworkConnectivityProbe], a lightweight, dependency-free
/// implementation of the domain [ConnectivityProbe] over `dart:io` (design §7,
/// Req 4).
///
/// It answers a single, deliberately modest question — *does the device
/// currently look like it has internet access?* — and surfaces the answer as a
/// [ConnectivityStatus] via [ValueListenable] so the AI Panel can show a
/// non-blocking offline hint (Req 4.2) that updates as connectivity changes
/// (Req 4.5). It is a **UI hint only** (Req 4.4): a failed or wrong check never
/// throws, never blocks, and never disables an offline-capable feature — it just
/// reports [ConnectivityStatus.offline] (a check failed) or, on the very first
/// tick before any check has resolved, [ConnectivityStatus.unknown].
///
/// ### Why no `connectivity_plus`
/// The app deliberately avoids adding a heavy platform plugin for what is only a
/// UI hint. Instead the probe performs a tolerant reachability check with
/// [InternetAddress.lookup] against a well-known host on a periodic timer. A DNS
/// lookup that returns at least one address is treated as online; a
/// [SocketException] (host lookup failed / network unreachable) is treated as
/// offline. This is cheap, cross-platform, and good enough for a hint.
///
/// ### Testability (task 4.2)
/// The actual reachability check is injected behind [ReachabilityCheck], so a
/// test can substitute a fake that resolves however the test wants and drive
/// [ConnectivityStatus] transitions deterministically without any real network
/// or DNS. The periodic interval is also injectable. Tests can either let the
/// timer fire or call [checkNow] directly to force a single check.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/ai/connectivity_probe.dart';

export '../../domain/ai/connectivity_probe.dart' show ConnectivityStatus;

/// Performs a single reachability check, completing with `true` when the device
/// appears to have internet access and `false` when it does not.
///
/// Injected into [NetworkConnectivityProbe] so tests can substitute a fake
/// source and drive transitions without real network access (task 4.2). An
/// implementation must be **tolerant**: it should resolve to `false` rather than
/// throw when connectivity is absent, since a thrown error would otherwise
/// bubble out of a background timer.
typedef ReachabilityCheck = Future<bool> Function();

/// A lightweight, tolerant [ConnectivityProbe] backed by a periodic reachability
/// check (default: a DNS lookup of a well-known host via `dart:io`).
///
/// Extends [ChangeNotifier] to satisfy the [ValueListenable] contract with the
/// same `flutter/foundation` listenable machinery the state layer already uses:
/// callers add a listener and read [value]. The status starts at
/// [ConnectivityStatus.unknown] and moves to [ConnectivityStatus.online] /
/// [ConnectivityStatus.offline] as checks resolve, notifying listeners only when
/// the value actually changes.
class NetworkConnectivityProbe extends ChangeNotifier
    implements ConnectivityProbe {
  /// A well-known, highly-available host used by the default reachability check.
  /// Only its reachability matters, not any content; a successful DNS lookup is
  /// enough to treat the device as online.
  static const String _defaultLookupHost = 'one.one.one.one';

  /// How often the probe re-checks connectivity so the hint stays current as
  /// connectivity changes (Req 4.5).
  static const Duration _defaultInterval = Duration(seconds: 10);

  /// The reachability check run on each tick. Defaults to a tolerant DNS lookup
  /// of a well-known host; overridden in tests with a fake (task 4.2).
  final ReachabilityCheck _check;

  /// How often [checkNow] is invoked while the probe is running.
  final Duration _interval;

  /// The recurring timer driving periodic checks; `null` until [start] and
  /// after [dispose].
  Timer? _timer;

  /// Guards against concurrent/overlapping checks: while a check is in flight,
  /// a timer tick that arrives before it resolves is skipped rather than
  /// stacking another lookup.
  bool _checkInFlight = false;

  /// Set once [dispose] has run so a late-completing check never notifies after
  /// disposal.
  bool _disposed = false;

  /// The latest determined status. Begins [ConnectivityStatus.unknown] until the
  /// first check resolves.
  ConnectivityStatus _value = ConnectivityStatus.unknown;

  /// Creates a probe.
  ///
  /// [check] defaults to a tolerant DNS lookup of a well-known host; pass a fake
  /// in tests to drive transitions deterministically (task 4.2). [interval]
  /// defaults to [_defaultInterval]; override it (e.g. a short duration) in
  /// tests that exercise the timer.
  NetworkConnectivityProbe({
    ReachabilityCheck? check,
    Duration? interval,
  })  : _check = check ?? _lookupReachability,
        _interval = interval ?? _defaultInterval;

  /// The most recently determined connectivity status (Req 4.1).
  @override
  ConnectivityStatus get value => _value;

  /// Begins detection: kicks off an immediate first check and starts the
  /// recurring timer that keeps [value] current (Req 4.5). Calling [start] when
  /// already running (or after [dispose]) is a no-op, so it is safe to call more
  /// than once.
  @override
  void start() {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(_interval, (_) => checkNow());
    // Run an immediate check so the hint doesn't sit at `unknown` for a full
    // interval before the first tick.
    checkNow();
  }

  /// Runs a single reachability check now and updates [value] accordingly,
  /// notifying listeners only when the status actually changes.
  ///
  /// Tolerant by contract (Req 4.4): the injected [ReachabilityCheck] is
  /// expected to resolve `false` rather than throw, but any error that does
  /// escape is caught and treated as offline so a background check can never
  /// crash the app or bubble out of the timer. Overlapping checks are skipped
  /// while one is in flight. Exposed (rather than private) so tests can force a
  /// check without waiting for the timer (task 4.2).
  Future<void> checkNow() async {
    if (_disposed || _checkInFlight) return;
    _checkInFlight = true;
    ConnectivityStatus next;
    try {
      final bool reachable = await _check();
      next = reachable
          ? ConnectivityStatus.online
          : ConnectivityStatus.offline;
    } catch (_) {
      // A failed check is not fatal and must not block offline-capable
      // features — report offline and carry on (Req 4.4).
      next = ConnectivityStatus.offline;
    } finally {
      _checkInFlight = false;
    }
    _setValue(next);
  }

  /// Updates [value] and notifies listeners only when the status changed and the
  /// probe has not been disposed (so a late check never fires after disposal).
  void _setValue(ConnectivityStatus next) {
    if (_disposed || next == _value) return;
    _value = next;
    notifyListeners();
  }

  /// Stops periodic checking and releases resources so no timer outlives the
  /// owner (Req 4.5). Safe to call more than once.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// The default reachability check: a tolerant DNS lookup of a well-known host.
  ///
  /// Resolves `true` when the lookup returns at least one address (the host is
  /// reachable → treat as online) and `false` on a [SocketException] (host
  /// lookup failed / network unreachable → treat as offline) or an empty result.
  /// It swallows failures rather than throwing, honoring the tolerant, hint-only
  /// contract (Req 4.4).
  static Future<bool> _lookupReachability() async {
    try {
      final List<InternetAddress> result =
          await InternetAddress.lookup(_defaultLookupHost)
              .timeout(const Duration(seconds: 5));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
