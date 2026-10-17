/// The listenables an engine hands to the UI, made safe to outlive it.
library;

import 'package:flutter/foundation.dart';

/// A [ValueNotifier] an engine can dispose while widgets still hold it.
///
/// An engine releases its listenables in `close()`, but the UI that reads
/// them does not go away on the same frame: a sheet still open over the
/// room, or a lazily built list row scrolled back into view while the sheet
/// animates out, mounts a fresh `ValueListenableBuilder` on a notifier that
/// is already disposed — and a plain [ValueNotifier] asserts on that
/// `addListener` ("used after being disposed", seen ending a jam with the
/// room sheet open on 2026-10-17). Once disposed, this one keeps its last
/// value readable and treats everything else — new listeners, removals,
/// writes, notifications — as a no-op: the session is over, nothing will
/// change again, and a late subscriber simply never hears from it.
class EngineValueNotifier<T> extends ValueNotifier<T> {
  EngineValueNotifier(super.value);

  bool _released = false;

  /// Whether [dispose] ran: the value is final from here on.
  bool get isReleased => _released;

  @override
  set value(T newValue) {
    if (_released) return;
    super.value = newValue;
  }

  @override
  void addListener(VoidCallback listener) {
    if (_released) return;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    if (_released) return;
    super.removeListener(listener);
  }

  @override
  void notifyListeners() {
    if (_released) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_released) return;
    _released = true;
    super.dispose();
  }
}
