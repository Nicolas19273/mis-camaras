/// Modelos de grabación y lectura de las respuestas de cada marca.
/// Todo lo de este archivo es "puro" (sin red) para poder probarlo.
library;

// =============================================================================
// Modelos
// =============================================================================

/// Cómo graba una cámara.
enum RecordMode { continuous, motion, off, custom }

extension RecordModeText on RecordMode {
  String get label => switch (this) {
        RecordMode.continuous => 'Siempre (24/7)',
        RecordMode.motion => 'Con movimiento',
        RecordMode.off => 'No graba',
        RecordMode.custom => 'Horario personalizado',
      };
}

/// Estado que se muestra sobre cada cámara.
enum RecState {
  /// Hay video grabado hace muy poco: está grabando.
  recording,

  /// Lista para grabar (con movimiento o según su horario), sin video reciente.
  armed,

  /// Debería grabar pero no puede (sin disco, disco con error, etc.).
  problem,

  /// La grabación está apagada a propósito.
  off,

  /// No se sabe (no respondió, marca sin soporte...).
  unknown,
}

/// Un disco duro o tarjeta SD del equipo.
class StorageDisk {
  const StorageDisk({
    required this.id,
    required this.name,
    required this.status,
    this.capacityMB = 0,
    this.freeMB = 0,
    this.path,
  });

  final String id;
  final String name;

  /// ok, unformatted, formatting, error o missing.
  final String status;
  final double capacityMB;
  final double freeMB;

  /// Ruta interna del equipo (Dahua la necesita para formatear).
  final String? path;

  bool get ok => status == 'ok';
  bool get needsFormat => status == 'unformatted';

  double get usedFraction =>
      capacityMB <= 0 ? 0 : ((capacityMB - freeMB) / capacityMB).clamp(0.0, 1.0).toDouble();

  String get statusLabel => switch (status) {
        'ok' => 'Funcionando',
        'unformatted' => 'Sin formatear',
        'formatting' => 'Formateando…',
        'missing' => 'No instalado',
        _ => 'Con error',
      };
}

/// Resultado completo de revisar un equipo.
class RecordingReport {
  RecordingReport({
    required this.disks,
    required this.modes,
    required this.lastEnd,
    required this.deviceNow,
  });

  /// Discos y tarjetas. null = no se pudo leer (no es lo mismo que "no tiene").
  final List<StorageDisk>? disks;

  /// Modo de cada canal (1, 2, 3...).
  final Map<int, RecordMode> modes;

  /// Fin del último video de cada canal (hora del equipo). Solo tiene los
  /// canales cuya búsqueda respondió bien: si falta, no se pudo buscar.
  final Map<int, DateTime?> lastEnd;

  /// Hora actual del equipo.
  final DateTime deviceNow;

  /// true = funciona, false = no tiene o falla, null = no se sabe.
  /// Si hay video reciente, el disco evidentemente funciona.
  bool? get storageOk {
    final d = disks;
    if (d != null && d.any((x) => x.ok)) return true;
    final recent = deviceNow.subtract(continuousWindow);
    if (lastEnd.values.any((t) => t != null && !t.isBefore(recent))) return true;
    return d == null ? null : false;
  }

  /// [inGrace] = recién configurada: todavía puede no haber video nuevo.
  RecState stateOf(int channel, {bool inGrace = false}) => evaluateRecording(
        mode: modes[channel],
        storageOk: storageOk,
        searched: lastEnd.containsKey(channel),
        lastEnd: lastEnd[channel],
        now: deviceNow,
        inGrace: inGrace,
      );
}

/// Con grabación continua, cuánto puede tener el último video guardado sin
/// que sea raro (los equipos guardan en archivos de hasta 1–2 horas).
const continuousWindow = Duration(hours: 3);

/// Con movimiento: el "● REC" parpadea si hubo video en estos minutos.
const motionWindow = Duration(minutes: 15);

/// Decide qué mostrar para una cámara. Solo dice "no está grabando" con
/// pruebas: sin disco, o sin ningún video en horas teniendo que grabar siempre.
/// Si algo no se pudo revisar, confía en la configuración del equipo.
RecState evaluateRecording({
  required RecordMode? mode,
  required bool? storageOk,
  required bool searched,
  required DateTime? lastEnd,
  required DateTime now,
  bool inGrace = false,
}) {
  if (mode == RecordMode.off) return RecState.off;
  bool within(Duration d) => lastEnd != null && !lastEnd.isBefore(now.subtract(d));

  if (storageOk == false) return mode == null ? RecState.unknown : RecState.problem;
  switch (mode) {
    case RecordMode.continuous:
      if (within(continuousWindow)) return RecState.recording;
      if (!searched || inGrace) return storageOk == null && !inGrace ? RecState.unknown : RecState.recording;
      return RecState.problem;
    case RecordMode.motion:
    case RecordMode.custom:
      return within(motionWindow) ? RecState.recording : RecState.armed;
    case RecordMode.off:
      return RecState.off;
    case null:
      return within(motionWindow) ? RecState.recording : RecState.unknown;
  }
}

// =============================================================================
// Fechas
// =============================================================================

/// Lee "2026-11-27T18:05:09Z", "2026-11-27 18:05:09", "2026-11-27T18:05:09-03:00"
/// o "20261127T180509Z" como hora local del equipo (sin zona).
DateTime? parseDeviceTime(String? text) {
  if (text == null) return null;
  final m = RegExp(r'(\d{4})-?(\d{1,2})-?(\d{1,2})[T\s]+(\d{1,2}):?(\d{2}):?(\d{2})').firstMatch(text);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// 2026-11-27T18:05:09Z (Hikvision usa la hora local con "Z").
String hikvisionTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}Z';

/// 2026-11-27 18:05:09 (Dahua).
String dahuaTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

int _seconds(String hms) {
  final p = hms.trim().split(':').map((e) => int.tryParse(e) ?? 0).toList();
  while (p.length < 3) {
    p.add(0);
  }
  return p[0] * 3600 + p[1] * 60 + p[2];
}

const _fullDay = 86399; // 23:59:59 cuenta como día completo

String? _tag(String xml, String tag) {
  final m = RegExp('<(?:[\\w-]+:)?$tag(?:\\s[^>]*)?>([^<]*)</(?:[\\w-]+:)?$tag>').firstMatch(xml);
  final v = m?.group(1)?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

// =============================================================================
// Hikvision
// =============================================================================

const hikvisionDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Pista de grabación del canal (101, 201...).
int hikvisionTrack(int channel) => channel * 100 + 1;

String _normalizeHikStatus(String? s) {
  final t = (s ?? '').toLowerCase().trim();
  if (t == 'ok' || t == 'idle' || t == 'sleep' || t == 'sleeping' || t == 'normal') return 'ok';
  if (t == 'unformatted' || t == 'uninitialized' || t == 'uninitialised') return 'unformatted';
  if (t.startsWith('format')) return 'formatting';
  if (t == 'notexist' || t == 'nocard' || t == 'notexists' || t == 'absent') return 'missing';
  return 'error';
}

/// GET /ISAPI/ContentMgmt/Storage → discos (capacidad y espacio libre en MB).
List<StorageDisk> parseHikvisionStorage(String xml) {
  final result = <StorageDisk>[];
  for (final m in RegExp(r'<hdd(?:\s[^>]*)?>([\s\S]*?)</hdd>').allMatches(xml)) {
    final b = m.group(1)!;
    final id = _tag(b, 'id');
    if (id == null) continue;
    result.add(StorageDisk(
      id: id,
      name: _tag(b, 'hddName') ?? 'Disco $id',
      status: _normalizeHikStatus(_tag(b, 'status')),
      capacityMB: double.tryParse(_tag(b, 'capacity') ?? '') ?? 0,
      freeMB: double.tryParse(_tag(b, 'freeSpace') ?? '') ?? 0,
      path: _tag(b, 'hddPath'),
    ));
  }
  return result;
}

/// Lee el modo de una pista (GET /ISAPI/ContentMgmt/record/tracks/101).
RecordMode parseHikvisionTrackMode(String xml) {
  final enabled = RegExp(r'<enableSchedule>\s*(\w+)\s*</enableSchedule>').firstMatch(xml)?.group(1);
  if (enabled == 'false') return RecordMode.off;
  final actions = RegExp(r'<ScheduleAction>([\s\S]*?)</ScheduleAction>').allMatches(xml).toList();
  if (actions.isEmpty) return RecordMode.off;

  final continuous = <String, int>{};
  final events = <String, int>{};
  var other = false;
  for (final a in actions) {
    final b = a.group(1)!;
    if ((_tag(b, 'Record') ?? 'true') == 'false') continue;
    final start = RegExp(r'<ScheduleActionStartTime>([\s\S]*?)</ScheduleActionStartTime>').firstMatch(b)?.group(1) ?? '';
    final end = RegExp(r'<ScheduleActionEndTime>([\s\S]*?)</ScheduleActionEndTime>').firstMatch(b)?.group(1) ?? '';
    final day = _tag(start, 'DayOfWeek') ?? '';
    final endDay = _tag(end, 'DayOfWeek') ?? day;
    if (day != endDay) {
      other = true;
      continue;
    }
    final secs = _seconds(_tag(end, 'TimeOfDay') ?? '0') - _seconds(_tag(start, 'TimeOfDay') ?? '0');
    final mode = (_tag(b, 'ActionRecordingMode') ?? 'CMR').toUpperCase();
    if (mode == 'CMR') {
      continuous[day] = (continuous[day] ?? 0) + secs;
    } else {
      events[day] = (events[day] ?? 0) + secs;
    }
  }
  bool full(Map<String, int> m) => hikvisionDays.every((d) => (m[d] ?? 0) >= _fullDay);
  if (!other && full(continuous)) return RecordMode.continuous;
  if (!other && continuous.isEmpty && full(events)) return RecordMode.motion;
  if (continuous.isEmpty && events.isEmpty && !other) return RecordMode.off;
  return RecordMode.custom;
}

const _hikDefaultAction = '<ScheduleAction><id>1</id>'
    '<ScheduleActionStartTime><DayOfWeek>Monday</DayOfWeek><TimeOfDay>00:00:00</TimeOfDay></ScheduleActionStartTime>'
    '<ScheduleActionEndTime><DayOfWeek>Monday</DayOfWeek><TimeOfDay>24:00:00</TimeOfDay></ScheduleActionEndTime>'
    '<ScheduleDSTEnable>false</ScheduleDSTEnable><Description>nothing</Description>'
    '<Actions><Record>true</Record><Log>false</Log><SaveImg>false</SaveImg>'
    '<ActionRecordingMode>CMR</ActionRecordingMode></Actions></ScheduleAction>';

String _hikAction(String template, int id, String day, String recMode) {
  var a = template.replaceFirst(RegExp(r'<id>[^<]*</id>'), '<id>$id</id>');
  RegExp timeRe(String tag) =>
      RegExp('(<$tag>[\\s\\S]*?<DayOfWeek>)[^<]*(</DayOfWeek>[\\s\\S]*?<TimeOfDay>)[^<]*(</TimeOfDay>)');
  a = a.replaceFirstMapped(timeRe('ScheduleActionStartTime'), (m) => '${m[1]}$day${m[2]}00:00:00${m[3]}');
  a = a.replaceFirstMapped(timeRe('ScheduleActionEndTime'), (m) => '${m[1]}$day${m[2]}24:00:00${m[3]}');
  if (a.contains('<ActionRecordingMode>')) {
    a = a.replaceFirst(RegExp(r'<ActionRecordingMode>[^<]*</ActionRecordingMode>'),
        '<ActionRecordingMode>$recMode</ActionRecordingMode>');
  } else if (a.contains('</Actions>')) {
    a = a.replaceFirst('</Actions>', '<ActionRecordingMode>$recMode</ActionRecordingMode></Actions>');
  }
  a = a.replaceFirst(RegExp(r'<Record>[^<]*</Record>'), '<Record>true</Record>');
  return a;
}

/// Arma la pista con el modo nuevo, conservando todo lo demás del equipo.
String buildHikvisionTrack(String current, RecordMode mode) {
  var xml = current;
  final hasEnableSchedule = xml.contains('<enableSchedule>');
  if (hasEnableSchedule) {
    xml = xml.replaceFirst(RegExp(r'<enableSchedule>[^<]*</enableSchedule>'),
        '<enableSchedule>${mode != RecordMode.off}</enableSchedule>');
  }
  final actionRe = RegExp(r'<ScheduleAction>[\s\S]*?</ScheduleAction>');

  if (mode == RecordMode.off) {
    // Sin "enableSchedule", se apaga dejando el horario vacío.
    return hasEnableSchedule ? xml : xml.replaceAll(actionRe, '');
  }

  // La pista misma tiene que estar activada (primer <Enable> del documento).
  xml = xml.replaceFirst(RegExp(r'<Enable>\s*false\s*</Enable>'), '<Enable>true</Enable>');

  final recMode = mode == RecordMode.motion ? 'MOTION' : 'CMR';
  final template = actionRe.firstMatch(xml)?.group(0) ?? _hikDefaultAction;
  final actions = [
    for (var i = 0; i < hikvisionDays.length; i++) _hikAction(template, i + 1, hikvisionDays[i], recMode),
  ].join();

  if (xml.contains('</ScheduleBlock>')) {
    xml = xml.replaceAll(actionRe, '');
    return xml.replaceFirst('</ScheduleBlock>', '$actions</ScheduleBlock>');
  }
  const blockStart = '<ScheduleBlock><ScheduleBlockGUID>{00000000-0000-0000-0000-000000000000}</ScheduleBlockGUID>'
      '<ScheduleBlockType>www.std-cgi.com/racm/schedule/ver10</ScheduleBlockType>';
  final block = '$blockStart$actions</ScheduleBlock>';
  if (xml.contains('<TrackSchedule/>')) {
    return xml.replaceFirst('<TrackSchedule/>', '<TrackSchedule>$block</TrackSchedule>');
  }
  if (xml.contains('<TrackSchedule>')) {
    return xml.replaceFirst('<TrackSchedule>', '<TrackSchedule>$block');
  }
  return xml.replaceFirst('</Track>', '<TrackSchedule>$block</TrackSchedule></Track>');
}

/// Búsqueda de videos grabados de varias pistas en un rango de tiempo.
String buildHikvisionSearch(String searchId, List<int> tracks, DateTime from, DateTime to,
    {int position = 0, int maxResults = 100}) {
  return '<?xml version="1.0" encoding="utf-8"?><CMSearchDescription>'
      '<searchID>$searchId</searchID>'
      '<trackList>${tracks.map((t) => '<trackID>$t</trackID>').join()}</trackList>'
      '<timeSpanList><timeSpan><startTime>${hikvisionTime(from)}</startTime>'
      '<endTime>${hikvisionTime(to)}</endTime></timeSpan></timeSpanList>'
      '<maxResults>$maxResults</maxResults><searchResultPostion>$position</searchResultPostion>'
      '<metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList>'
      '</CMSearchDescription>';
}

typedef RecordedSpan = ({int channel, DateTime start, DateTime end});

/// Respuesta de la búsqueda: videos encontrados y si hay más (MORE).
({List<RecordedSpan> spans, bool more}) parseHikvisionSearch(String xml) {
  final spans = <RecordedSpan>[];
  for (final m in RegExp(r'<(searchMatchItem|matchElement)>([\s\S]*?)</\1>').allMatches(xml)) {
    final b = m.group(2)!;
    final track = int.tryParse(_tag(b, 'trackID') ?? '');
    final start = parseDeviceTime(_tag(b, 'startTime'));
    final end = parseDeviceTime(_tag(b, 'endTime') ?? _tag(b, 'endTIme'));
    if (track == null || start == null || end == null) continue;
    spans.add((channel: track ~/ 100, start: start, end: end));
  }
  final status = (_tag(xml, 'responseStatusStrg') ?? '').toUpperCase();
  return (spans: spans, more: status == 'MORE');
}

/// Agrega el aviso "grabar" a la detección de movimiento (si no lo tiene).
/// Las cámaras usan videoInputID y los grabadores dynVideoInputID.
String? addHikvisionRecordLinkage(String trigger, int channel) {
  if (RegExp(r'<notificationMethod>\s*record\s*</notificationMethod>').hasMatch(trigger)) return null;
  final input = trigger.contains('dynVideoInputChannelID')
      ? '<dynVideoInputID>$channel</dynVideoInputID>'
      : '<videoInputID>$channel</videoInputID>';
  final notification = '<EventTriggerNotification><id>record-$channel</id>'
      '<notificationMethod>record</notificationMethod>'
      '<notificationRecurrence>beginning</notificationRecurrence>$input</EventTriggerNotification>';
  if (trigger.contains('</EventTriggerNotificationList>')) {
    return trigger.replaceFirst('</EventTriggerNotificationList>', '$notification</EventTriggerNotificationList>');
  }
  if (trigger.contains('<EventTriggerNotificationList/>')) {
    return trigger.replaceFirst('<EventTriggerNotificationList/>',
        '<EventTriggerNotificationList>$notification</EventTriggerNotificationList>');
  }
  if (!trigger.contains('</EventTrigger>')) return null;
  return trigger.replaceFirst('</EventTrigger>',
      '<EventTriggerNotificationList>$notification</EventTriggerNotificationList></EventTrigger>');
}

// =============================================================================
// Dahua
// =============================================================================

/// "list.info[0].Detail[0].TotalBytes=..." → discos.
List<StorageDisk> parseDahuaStorage(String body) {
  final disks = <int, Map<String, String>>{};
  final totals = <int, double>{};
  final used = <int, double>{};
  final errors = <int>{};
  for (final line in body.split(RegExp(r'\r?\n'))) {
    final m = RegExp(r'list\.info\[(\d+)\]\.(.+?)=(.*)$').firstMatch(line.trim());
    if (m == null) continue;
    final i = int.parse(m.group(1)!);
    final key = m.group(2)!;
    final value = m.group(3)!.trim();
    disks.putIfAbsent(i, () => {});
    if (key.endsWith('TotalBytes')) {
      totals[i] = (totals[i] ?? 0) + (double.tryParse(value) ?? 0);
    } else if (key.endsWith('UsedBytes')) {
      used[i] = (used[i] ?? 0) + (double.tryParse(value) ?? 0);
    } else if (key.endsWith('IsError') && value == 'true') {
      errors.add(i);
    } else if (!key.contains('Detail')) {
      disks[i]![key] = value;
    }
  }
  const mb = 1024 * 1024;
  final result = <StorageDisk>[];
  for (final i in disks.keys.toList()..sort()) {
    final state = disks[i]!['State'] ?? '';
    final total = totals[i] ?? 0;
    final String status;
    if (state == 'Initializing') {
      status = 'formatting';
    } else if (errors.contains(i) || state == 'Error') {
      status = 'error';
    } else if (total <= 0) {
      status = 'unformatted';
    } else {
      status = 'ok';
    }
    final path = disks[i]!['Name'] ?? '';
    final name = path.contains('mmc')
        ? 'Tarjeta SD'
        : path.contains('/dev/sd')
            ? 'Disco duro ${i + 1}'
            : (path.isEmpty ? 'Disco ${i + 1}' : path);
    result.add(StorageDisk(
      id: '$i',
      name: name,
      status: status,
      capacityMB: total / mb,
      freeMB: (total - (used[i] ?? 0)) / mb,
      path: path.isEmpty ? null : path,
    ));
  }
  return result;
}

/// Lee RecordMode y Record (horario) de Dahua → modo de cada canal (desde 1).
Map<int, RecordMode> parseDahuaModes(String recordModeBody, String recordBody, int channels) {
  final modeValue = <int, int>{};
  for (final m in RegExp(r'RecordMode\[(\d+)\]\.Mode=(\d+)').allMatches(recordModeBody)) {
    modeValue[int.parse(m.group(1)!)] = int.parse(m.group(2)!);
  }
  // [canal][día] → lista de (máscara, segundos)
  final slots = <int, Map<int, List<(int, int)>>>{};
  final re = RegExp(r'Record\[(\d+)\]\.TimeSection\[(\d+)\]\[\d+\]=(\d+)\s+([\d:]+)-([\d:]+)');
  for (final m in re.allMatches(recordBody)) {
    final ch = int.parse(m.group(1)!);
    final day = int.parse(m.group(2)!);
    if (day > 6) continue; // 7 = feriados
    final mask = int.parse(m.group(3)!);
    final secs = _seconds(m.group(5)!) - _seconds(m.group(4)!);
    slots.putIfAbsent(ch, () => {}).putIfAbsent(day, () => []).add((mask, secs));
  }

  RecordMode fromSchedule(int ch) {
    final days = slots[ch];
    if (days == null) return RecordMode.custom;
    bool full(int bits) => List.generate(7, (d) => d).every((d) {
          final total = (days[d] ?? const <(int, int)>[])
              .where((s) => (s.$1 & bits) != 0)
              .fold<int>(0, (sum, s) => sum + s.$2);
          return total >= _fullDay;
        });
    final any = days.values.any((l) => l.any((s) => s.$1 != 0 && s.$2 > 0));
    if (!any) return RecordMode.off;
    if (full(1)) return RecordMode.continuous;
    if (full(2 | 4)) return RecordMode.motion;
    return RecordMode.custom;
  }

  return {
    for (var ch = 1; ch <= channels; ch++)
      ch: switch (modeValue[ch - 1]) {
        2 => RecordMode.off,
        1 => RecordMode.continuous,
        _ => fromSchedule(ch - 1),
      },
  };
}

/// Cuántos tramos por día tiene el horario de un canal (para borrar los demás).
int dahuaSlotsPerDay(String recordBody, int index) {
  var max = 0;
  for (final m in RegExp('Record\\[$index\\]\\.TimeSection\\[0\\]\\[(\\d+)\\]').allMatches(recordBody)) {
    final n = int.parse(m.group(1)!) + 1;
    if (n > max) max = n;
  }
  return max == 0 ? 6 : max;
}

/// Parámetros de setConfig para dejar un canal (índice desde 0) en el modo pedido.
List<String> dahuaModeParams(int index, RecordMode mode, {int slotsPerDay = 6, bool holiday = false}) {
  if (mode == RecordMode.off) return ['RecordMode[$index].Mode=2'];
  // 1 = normal, 2 = movimiento, 4 = alarma.
  final mask = mode == RecordMode.motion ? 6 : 7;
  return [
    'RecordMode[$index].Mode=0',
    for (var day = 0; day <= (holiday ? 7 : 6); day++)
      for (var slot = 0; slot < slotsPerDay; slot++)
        'Record[$index].TimeSection[$day][$slot]=${slot == 0 ? mask : 0} 00:00:00-24:00:00',
  ];
}

/// Respuesta de findNextFile → fin del último video.
DateTime? parseDahuaLastFileEnd(String body) {
  DateTime? last;
  for (final m in RegExp(r'items\[\d+\]\.EndTime=(.+)').allMatches(body)) {
    final t = parseDeviceTime(m.group(1));
    if (t != null && (last == null || t.isAfter(last))) last = t;
  }
  return last;
}
