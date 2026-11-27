import 'package:flutter_test/flutter_test.dart';
import 'package:mis_camaras/recording/recording.dart';

/// Pruebas de la grabación (lectura y armado de configuraciones).
void main() {
  group('Fechas', () {
    test('Lee las horas de cada marca', () {
      expect(parseDeviceTime('result=2011-7-3 21:02:32'), DateTime(2011, 7, 3, 21, 2, 32));
      expect(parseDeviceTime('2026-11-27T18:53:00-03:00'), DateTime(2026, 11, 27, 18, 53));
      expect(parseDeviceTime('20261127T180509Z'), DateTime(2026, 11, 27, 18, 5, 9));
      expect(parseDeviceTime('nada'), isNull);
      expect(hikvisionTime(DateTime(2026, 1, 2, 3, 4, 5)), '2026-01-02T03:04:05Z');
      expect(dahuaTime(DateTime(2026, 1, 2, 3, 4, 5)), '2026-01-02 03:04:05');
    });
  });

  group('Estado REC', () {
    final now = DateTime(2026, 11, 27, 19);
    RecState eval(RecordMode? m, {bool? disk = true, bool searched = true, DateTime? last, bool grace = false}) =>
        evaluateRecording(mode: m, storageOk: disk, searched: searched, lastEnd: last, now: now, inGrace: grace);

    test('Grabando si hay video de las últimas horas', () {
      expect(eval(RecordMode.continuous, last: now.subtract(const Duration(minutes: 70))), RecState.recording);
    });
    test('Solo es problema con pruebas: buscó y no hay nada en horas', () {
      expect(eval(RecordMode.continuous, last: now.subtract(const Duration(hours: 5))), RecState.problem);
      expect(eval(RecordMode.continuous), RecState.problem);
    });
    test('Si la búsqueda falló, confía en la configuración', () {
      expect(eval(RecordMode.continuous, searched: false), RecState.recording);
      expect(eval(RecordMode.continuous, searched: false, disk: null), RecState.unknown);
    });
    test('Recién configurada no es problema', () {
      expect(eval(RecordMode.continuous, grace: true), RecState.recording);
    });
    test('Con movimiento: lista, o REC si hubo video hace poco', () {
      expect(eval(RecordMode.motion), RecState.armed);
      expect(eval(RecordMode.motion, last: now.subtract(const Duration(minutes: 5))), RecState.recording);
    });
    test('Sin disco es un problema; apagada es apagada', () {
      expect(eval(RecordMode.continuous, disk: false), RecState.problem);
      expect(eval(RecordMode.off, disk: false), RecState.off);
    });
    test('Video reciente prueba que el disco funciona aunque no se pudo leer', () {
      final r = RecordingReport(
        disks: null,
        modes: {1: RecordMode.continuous, 2: RecordMode.continuous},
        lastEnd: {1: now.subtract(const Duration(minutes: 2))},
        deviceNow: now,
      );
      expect(r.storageOk, isTrue);
      expect(r.stateOf(1), RecState.recording);
      expect(r.stateOf(2), RecState.recording); // canal 2 sin buscar: confía en la configuración
    });
  });

  group('Hikvision', () {
    const storage = '<storage><hddList>'
        '<hdd version="2.0"><id>1</id><hddName>hdd1</hddName><hddType>SATA</hddType><status>ok</status>'
        '<capacity>1907729</capacity><freeSpace>953864</freeSpace><property>RW</property></hdd>'
        '<hdd><id>2</id><hddName>hdd2</hddName><status>unformatted</status><capacity>0</capacity>'
        '<freeSpace>0</freeSpace></hdd></hddList><nasList/></storage>';

    test('Lee los discos', () {
      final disks = parseHikvisionStorage(storage);
      expect(disks.length, 2);
      expect(disks[0].ok, isTrue);
      expect(disks[0].capacityMB, 1907729);
      expect(disks[0].usedFraction, closeTo(0.5, 0.01));
      expect(disks[1].needsFormat, isTrue);
    });

    const track = '<Track version="1.0" xmlns="http://www.hikvision.com/ver20/XMLSchema">'
        '<id>101</id><Channel>101</Channel><Enable>false</Enable><Description>trackType=standard</Description>'
        '<DefaultRecordingMode>CMR</DefaultRecordingMode><LoopEnable>true</LoopEnable>'
        '<TrackSchedule><ScheduleBlock><ScheduleBlockGUID>{00000000-0000-0000-0000-000000000000}</ScheduleBlockGUID>'
        '<ScheduleBlockType>www.std-cgi.com/racm/schedule/ver10</ScheduleBlockType>'
        '<ScheduleAction><id>1</id>'
        '<ScheduleActionStartTime><DayOfWeek>Monday</DayOfWeek><TimeOfDay>08:00:00</TimeOfDay></ScheduleActionStartTime>'
        '<ScheduleActionEndTime><DayOfWeek>Monday</DayOfWeek><TimeOfDay>18:00:00</TimeOfDay></ScheduleActionEndTime>'
        '<ScheduleDSTEnable>false</ScheduleDSTEnable><Description>nothing</Description>'
        '<Actions><Record>true</Record><Log>false</Log><SaveImg>false</SaveImg>'
        '<ActionRecordingMode>CMR</ActionRecordingMode></Actions></ScheduleAction>'
        '</ScheduleBlock></TrackSchedule>'
        '<CustomExtensionList><CustomExtension><CustomExtensionName>www.hikvision.com/RaCM/trackCustomExt/ver10'
        '</CustomExtensionName><enableSchedule>true</enableSchedule><SaveAudio>false</SaveAudio>'
        '</CustomExtension></CustomExtensionList></Track>';

    test('Horario parcial = personalizado', () {
      expect(parseHikvisionTrackMode(track), RecordMode.custom);
    });

    test('Siempre: 7 días completos, conserva lo demás y activa la pista', () {
      final xml = buildHikvisionTrack(track, RecordMode.continuous);
      expect(RegExp('<ScheduleAction>').allMatches(xml).length, 7);
      expect(xml, contains('<DayOfWeek>Sunday</DayOfWeek>'));
      expect(xml, contains('<SaveAudio>false</SaveAudio>'));
      expect(xml, contains('<Enable>true</Enable>'));
      expect(parseHikvisionTrackMode(xml), RecordMode.continuous);
    });

    test('Con movimiento', () {
      final xml = buildHikvisionTrack(track, RecordMode.motion);
      expect(xml, contains('<ActionRecordingMode>MOTION</ActionRecordingMode>'));
      expect(parseHikvisionTrackMode(xml), RecordMode.motion);
    });

    test('Apagar', () {
      final xml = buildHikvisionTrack(track, RecordMode.off);
      expect(xml, contains('<enableSchedule>false</enableSchedule>'));
      expect(parseHikvisionTrackMode(xml), RecordMode.off);
    });

    test('Pista sin horario: lo crea', () {
      const empty = '<Track><id>201</id><Enable>true</Enable><TrackSchedule/></Track>';
      final xml = buildHikvisionTrack(empty, RecordMode.continuous);
      expect(xml, contains('<ScheduleBlockType>'));
      expect(parseHikvisionTrackMode(xml), RecordMode.continuous);
      expect(parseHikvisionTrackMode(buildHikvisionTrack(xml, RecordMode.off)), RecordMode.off);
    });

    test('Búsqueda de videos', () {
      final req = buildHikvisionSearch('abc', [101, 201], DateTime(2026, 11, 27, 17), DateTime(2026, 11, 27, 19));
      expect(req, contains('<trackID>201</trackID>'));
      expect(req, contains('<startTime>2026-11-27T17:00:00Z</startTime>'));
      const res = '<CMSearchResult><searchID>abc</searchID><responseStatus>true</responseStatus>'
          '<responseStatusStrg>MORE</responseStatusStrg><numOfMatches>2</numOfMatches><matchList>'
          '<searchMatchItem><trackID>201</trackID><timeSpan><startTime>2026-11-27T17:00:00Z</startTime>'
          '<endTime>2026-11-27T18:10:00Z</endTime></timeSpan></searchMatchItem>'
          '<searchMatchItem><trackID>201</trackID><timeSpan><startTime>2026-11-27T18:10:00Z</startTime>'
          '<endTime>2026-11-27T18:52:30Z</endTime></timeSpan></searchMatchItem>'
          '</matchList></CMSearchResult>';
      final parsed = parseHikvisionSearch(res);
      expect(parsed.more, isTrue);
      expect(parsed.spans.length, 2);
      expect(parsed.spans.last.channel, 2);
      expect(parsed.spans.last.end, DateTime(2026, 11, 27, 18, 52, 30));
    });

    test('Movimiento → grabar (cámara y grabador)', () {
      const cam = '<EventTrigger><id>VMD-1</id><eventType>VMD</eventType><videoInputChannelID>1</videoInputChannelID>'
          '<EventTriggerNotificationList><EventTriggerNotification><id>center</id>'
          '<notificationMethod>center</notificationMethod></EventTriggerNotification>'
          '</EventTriggerNotificationList></EventTrigger>';
      final updated = addHikvisionRecordLinkage(cam, 1)!;
      expect(updated, contains('<notificationMethod>record</notificationMethod>'));
      expect(updated, contains('<videoInputID>1</videoInputID>'));
      expect(addHikvisionRecordLinkage(updated, 1), isNull);

      const nvr = '<EventTrigger><id>VMD-4</id><dynVideoInputChannelID>4</dynVideoInputChannelID>'
          '<EventTriggerNotificationList/></EventTrigger>';
      expect(addHikvisionRecordLinkage(nvr, 4), contains('<dynVideoInputID>4</dynVideoInputID>'));
    });
  });

  group('Dahua', () {
    test('Lee discos y tarjetas SD', () {
      const body = 'list.info[0].Detail[0].IsError=false\n'
          'list.info[0].Detail[0].TotalBytes=0\n'
          'list.info[0].Detail[0].UsedBytes=0\n'
          'list.info[0].Name=/dev/mmc0\n'
          'list.info[0].State=Success\n'
          'list.info[1].Detail[0].IsError=false\n'
          'list.info[1].Detail[0].TotalBytes=2000000000000.000000\n'
          'list.info[1].Detail[0].UsedBytes=500000000000.000000\n'
          'list.info[1].Detail[0].Path=/mnt/dvr/sda0\n'
          'list.info[1].Name=/dev/sda\n'
          'list.info[1].State=Success\n'
          'list.info[2].Detail[0].IsError=true\n'
          'list.info[2].Detail[0].TotalBytes=100\n'
          'list.info[2].Name=/dev/sdb\n'
          'list.info[2].State=Success\n';
      final disks = parseDahuaStorage(body);
      expect(disks.length, 3);
      expect(disks[0].name, 'Tarjeta SD');
      expect(disks[0].needsFormat, isTrue);
      expect(disks[0].path, '/dev/mmc0');
      expect(disks[1].ok, isTrue);
      expect(disks[1].usedFraction, closeTo(0.25, 0.01));
      expect(disks[2].status, 'error');
    });

    String schedule(int index, String slot0) => [
          for (var d = 0; d <= 6; d++) ...[
            'table.Record[$index].TimeSection[$d][0]=$slot0',
            'table.Record[$index].TimeSection[$d][1]=0 00:00:00-24:00:00',
          ],
        ].join('\n');

    test('Lee el modo de cada canal', () {
      const modes = 'table.RecordMode[0].Mode=0\ntable.RecordMode[1].Mode=2\n'
          'table.RecordMode[2].Mode=0\ntable.RecordMode[3].Mode=1\ntable.RecordMode[4].Mode=0\n'
          'table.RecordMode[5].Mode=0';
      final record = [
        schedule(0, '1 00:00:00-24:00:00'),
        schedule(1, '1 00:00:00-24:00:00'),
        schedule(2, '6 00:00:00-23:59:59'),
        schedule(3, '0 00:00:00-24:00:00'),
        schedule(4, '1 08:00:00-18:00:00'),
        schedule(5, '0 00:00:00-24:00:00'),
      ].join('\n');
      final m = parseDahuaModes(modes, record, 6);
      expect(m[1], RecordMode.continuous);
      expect(m[2], RecordMode.off);
      expect(m[3], RecordMode.motion);
      expect(m[4], RecordMode.continuous); // manual = siempre
      expect(m[5], RecordMode.custom);
      expect(m[6], RecordMode.off); // horario vacío
    });

    test('Arma el horario y se lee igual', () {
      final p = dahuaModeParams(2, RecordMode.continuous, slotsPerDay: 6);
      expect(p.first, 'RecordMode[2].Mode=0');
      expect(p.length, 1 + 7 * 6);
      expect(p, contains('Record[2].TimeSection[0][0]=7 00:00:00-24:00:00'));
      expect(p, contains('Record[2].TimeSection[6][5]=0 00:00:00-24:00:00'));
      expect(dahuaModeParams(0, RecordMode.off), ['RecordMode[0].Mode=2']);
      expect(dahuaModeParams(0, RecordMode.motion, holiday: true).length, 1 + 8 * 6);

      for (final mode in [RecordMode.continuous, RecordMode.motion]) {
        final body = dahuaModeParams(0, mode).map((e) => 'table.$e').join('\n');
        expect(parseDahuaModes(body, body, 1)[1], mode);
      }
    });

    test('Cuenta los tramos por día', () {
      expect(dahuaSlotsPerDay(schedule(1, '1 00:00:00-24:00:00'), 1), 2);
      expect(dahuaSlotsPerDay('', 0), 6);
    });

    test('Último video encontrado', () {
      const body = 'found=2\nitems[0].StartTime=2026-11-27 16:00:00\nitems[0].EndTime=2026-11-27 17:00:00\n'
          'items[1].StartTime=2026-11-27 17:00:00\nitems[1].EndTime=2026-11-27 18:00:05\n';
      expect(parseDahuaLastFileEnd(body), DateTime(2026, 11, 27, 18, 0, 5));
      expect(parseDahuaLastFileEnd('found=0'), isNull);
    });
  });
}
