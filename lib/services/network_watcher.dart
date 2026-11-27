import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/device.dart';
import '../models/network.dart';
import 'app_store.dart';
import 'device_api.dart';
import 'discovery.dart';
import 'network_config.dart';

/// Vigila a qué red está conectado el teléfono:
/// - Muestra solo los equipos de esa red (los demás quedan en espera).
/// - A los equipos sin red les asigna la actual cuando responden en ella.
/// - Lee de cada grabador qué cámaras tiene (para detectar repetidas).
class NetworkWatcher with WidgetsBindingObserver {
  NetworkWatcher(this.store);

  static const _channel = MethodChannel('mis_camaras/red');

  final AppStore store;
  Timer? _timer;
  bool _busy = false;
  final _synced = <String>{};
  final _triedAt = <String, DateTime>{};

  static NetworkWatcher? instance;

  void start() {
    instance = this;
    WidgetsBinding.instance.addObserver(this);
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _tick();
  }

  /// Vuelve a revisar ya (por ejemplo, después de dar el permiso).
  Future<void> refreshNow() => _tick(force: true);

  // --- Android --------------------------------------------------------------------

  static Future<NetInfo> read() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('wifiInfo');
      if (m != null) {
        return NetInfo(
          wifi: m['wifi'] == true,
          ssid: m['ssid'] as String?,
          ip: m['ip'] as String?,
          gateway: m['gateway'] as String?,
          locationOn: m['locationOn'] != false,
        );
      }
    } catch (_) {
      // Sin el canal (por ejemplo, en pruebas): se usa la IP.
    }
    final ip = await DiscoveryService.findLocalIp();
    return NetInfo(wifi: ip != null, ip: ip);
  }

  static Future<bool> hasPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasLocation') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestLocation') ?? false;
    } catch (_) {
      return false;
    }
  }

  // --- Revisión ---------------------------------------------------------------------

  Future<void> _tick({bool force = false}) async {
    if (_busy) return;
    _busy = true;
    try {
      final info = await read();
      final changed = store.updateNetInfo(info);
      if (changed || force || !store.probed) await _probeAndAssign(info);
      await _syncRecorders();
    } catch (_) {
      // Se reintenta en la próxima vuelta.
    } finally {
      _busy = false;
    }
  }

  /// Los equipos sin red que responden aquí pasan a ser de esta red.
  Future<void> _probeAndAssign(NetInfo info) async {
    final reachable = <String>{};
    if (info.hasNetwork) {
      final pending = store.devices.where((d) => d.isLocalHost && d.network == null).toList();
      await Future.wait(pending.map((d) async {
        if (await NetworkConfig.hostResponds(d.host, [d.httpPort, d.rtspPort])) reachable.add(d.id);
      }));
      if (reachable.isNotEmpty) {
        final net = store.ensureCurrentNetwork();
        if (net != null) await store.assignNetwork(reachable, net.id);
      }
    }
    store.setProbed(reachable);
  }

  /// Una vez por sesión, cada grabador de esta red dice qué cámaras tiene.
  Future<void> _syncRecorders() async {
    for (final d in store.activeDevices) {
      if (!d.isRecorder || !d.brand.hasFullApi || _synced.contains(d.id)) continue;
      final tried = _triedAt[d.id];
      if (tried != null && DateTime.now().difference(tried) < const Duration(minutes: 10)) continue;
      _triedAt[d.id] = DateTime.now();
      final api = DeviceApi(d);
      try {
        final hosts = await api.channelAddresses();
        if (hosts.isNotEmpty) _synced.add(d.id);
        final current = store.deviceById(d.id);
        if (current != null && hosts.isNotEmpty && !_sameMap(hosts, current.channelHosts)) {
          await store.saveDevice(current.copyWith(channelHosts: hosts));
        }
      } finally {
        api.close();
      }
    }
  }

  static bool _sameMap(Map<int, String> a, Map<int, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}
