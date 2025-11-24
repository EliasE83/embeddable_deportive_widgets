// scoreboard_widget.dart
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:scoreboard_widget/img_job.dart';
import 'package:scoreboard_widget/services/api_service.dart';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as js_util;
import 'package:socket_io_client/socket_io_client.dart' as io;
 
enum _GameState { pregame, inProgress, completed }

class ScoreboardWidget extends StatefulWidget {
  final String? leagueId;
  final DateTime? date;
  final String? seasonId;
  final String? teamId;
  final String? levelId;

  const ScoreboardWidget({
    super.key,
    this.leagueId,
    this.date,
    this.seasonId,
    this.teamId,
    this.levelId,
  });

  @override
  State<ScoreboardWidget> createState() => _ScoreboardWidgetState();
}

class _ScoreboardWidgetState extends State<ScoreboardWidget> {
  late DateTime _selectedDate;
  late String _leagueId;
  String? _seasonId;

  // Colores similares al SeasonScheduleTab
  Color primaryRed = const Color(0xFFdd1e36);
  Color primaryBlue = const Color(0xFF0c233f);
  Color textColor = const Color(0xFF000000);
  Color secondaryWhite = const Color(0xFFFFFFFF);
  Color tertiaryGrey = const Color(0xFF9ea1a6);
  String fontFamily = 'Roboto';

  List<Map<String, dynamic>> _games = [];
  //bool _isLoading = false;
  String? _errorMessage;

  final Map<String, io.Socket?> _sockets = {};
  final Map<String, int?> _lastEventsTs = {};
  final Map<String, int?> _lastRostersTs = {};
  final Set<String> _didSocketFirstSync = {};
  final Set<String> _fetchInFlight = {};

  int _loadGen = 0;
  bool _isLoadingSchedule = false;
  String? _levelId;
  String? _divisionId;

  final GlobalKey _contentKey = GlobalKey();
  double _lastReportedHeight = 0;

  final GlobalKey _dateButtonKey = GlobalKey();
  
  bool _imgCacheConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadCssVars();
    
    // Configurar caché de imágenes
    if(!_imgCacheConfigured) {
      ImageLoadScheduler.I.configureGlobalCache(entries: 100, bytesMB: 150);
      ImageLoadScheduler.I.maxConcurrent = 1; // Solo 1 carga a la vez (más estable)
      ImageLoadScheduler.I.targetPx = 45; // Tamaño de logos
      _imgCacheConfigured = true;
    }
    final uri = Uri.parse(html.window.location.href);
    final dateStr = uri.queryParameters['date'];
    
    _selectedDate = dateStr != null
      ? DateTime.tryParse(dateStr) ?? widget.date ?? DateTime.now()
      : widget.date ?? DateTime.now();
    
    _seasonId = uri.queryParameters['season'] ?? widget.seasonId ?? ApiService.defaultSeasonId;
    _leagueId = uri.queryParameters['league_id'] ?? widget.leagueId ?? ApiService.defaultLeagueId;
    _levelId = uri.queryParameters['level_id'];
    _divisionId = uri.queryParameters['division_id'];

    _fetchGames();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateUrl();
    });
  }

  @override
  void dispose() {
    for (final s in _sockets.values) {
      try { s?.off('clock'); } catch (_) {}
      try { s?.dispose(); } catch (_) {}
    }
    _sockets.clear();
    super.dispose();
  }

  void _reportHeightIfChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _contentKey.currentContext;
      if (ctx == null) {
        js.context.callMethod('setFlutterContainerHeight', [0]);
        return;
      }
      
      final render = ctx.findRenderObject();
      if (render is RenderBox) {
        final h = render.size.height;

        if ((h - _lastReportedHeight).abs() > 1) { 
          _lastReportedHeight = h;
          try {
            js.context.callMethod('setFlutterContainerHeight', [h]);
          } catch (_) {}
        }
      }
    });
  }



  void _loadCssVars() {
    final root = html.document.documentElement!;
    final jsStyles = js_util.callMethod(html.window, 'getComputedStyle', [root]);

    String readVar(String name) {
      final raw = js_util.callMethod(jsStyles, 'getPropertyValue', [name]) as String;
      return raw.trim();
    }

    Color parseHex(String hex) {
      final clean = hex.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      final withAlpha = (clean.length == 6 ? 'FF$clean' : clean).toUpperCase();
      return Color(int.parse(withAlpha, radix: 16));
    }

    setState(() {
      final pr = readVar('--app-primary-red');
      final pb = readVar('--app-primary-blue');
      final tc = readVar('--app-text-color');
      final sw = readVar('--app-secondary-white');
      final tg = readVar('--app-tertiary-grey');
      final ff = readVar('--app-font-family');

      primaryRed = pr.isNotEmpty ? parseHex(pr) : const Color(0xFFdd1e36);
      primaryBlue = pb.isNotEmpty ? parseHex(pb) : const Color(0xFF0c233f);
      textColor = tc.isNotEmpty ? parseHex(tc) : const Color(0xFF000000);
      secondaryWhite = sw.isNotEmpty ? parseHex(sw) : const Color(0xFFFFFFFF);
      tertiaryGrey = tg.isNotEmpty ? parseHex(tg) : const Color(0xFF9ea1a6);
      fontFamily = ff.isNotEmpty ? ff : 'Roboto';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged());
  }

  void _updateUrl() {
    final newUri = Uri(
      queryParameters: {
        'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
        if ((_leagueId).isNotEmpty) 'league_id': _leagueId,
        if ((_seasonId ?? '').isNotEmpty) 'season': _seasonId!,
        if (_levelId != null && _levelId!.isNotEmpty)
          'level_id': _levelId!,
        if (_divisionId != null && _divisionId!.isNotEmpty)
          'division_id': _divisionId!,
      },
    );
    html.window.history.replaceState(null, 'Scoreboard', newUri.toString());
  }

  Future<void> _fetchGames() async {
    final int myGen = ++_loadGen;

    _disposeAllSockets();

    setState(() {
      _isLoadingSchedule = true;
      _errorMessage = null;
      _games = [];
    });

    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final queryParameters = <String, String>{
        'league_id': _leagueId,
        'date': dateStr,
        if (_seasonId != null && _seasonId!.isNotEmpty) 'season_id': _seasonId!,
        if (_levelId != null && _levelId!.isNotEmpty) 'level_id': _levelId!,
        if (_divisionId != null && _divisionId!.isNotEmpty) 'division_id': _divisionId!,
      };

      final uri = ApiService.generateLink('get_schedule', moreQueries: queryParameters);
      final json = await ApiService.fetchData(uri);
      final gamesJson = (json['games'] as List? ?? []);

      final loadedGames = <Map<String, dynamic>>[];

      for (final game in gamesJson) {
        final gameData = Map<String, dynamic>.from(game);
        final rawGmt = gameData['gmt_time'];
        gameData['gmt_time'] = (rawGmt is DateTime)
          ? rawGmt
          : (rawGmt is String ? DateTime.tryParse(rawGmt.replaceFirst(' ', 'T')) : null);
        loadedGames.add(gameData);
      }

      loadedGames.sort((a, b) {
        final aTime = a['gmt_time'] as DateTime? ?? DateTime.tryParse('${a['date']} ${a['time']}');
        final bTime = b['gmt_time'] as DateTime? ?? DateTime.tryParse('${b['date']} ${b['time']}');
        if (aTime != null && bTime != null) return aTime.compareTo(bTime);
        return (a['time'] ?? '').toString().compareTo((b['time'] ?? '').toString());
      });

      if (!mounted || myGen != _loadGen) return; 

      setState(() {
        _games = loadedGames;
        _isLoadingSchedule = false; 
      });

      // Limpiar caché de imágenes al cargar nuevos juegos
      ImageLoadScheduler.I.clearAll();

      WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged());

      for (final g in loadedGames) {
        final id = g['game_id'].toString();
        _loadGameCenterIncremental(id, myGen); 
      }
    } catch (error) {
      if (!mounted || myGen != _loadGen) return;
      setState(() {
        _errorMessage = 'Error loading games: ${error.toString()}';
      });
    } finally {
      if (!mounted || myGen != _loadGen) return;
      setState(() {
        _isLoadingSchedule = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged());
    }
  }

  Future<void> _loadGameCenterIncremental(String gameId, int gen) async {
    try {
      final gc = await _loadGameCenter(gameId);
      if (!mounted || gen != _loadGen) return; 
      final idx = _games.indexWhere((g) => g['game_id'].toString() == gameId);
      if (idx >= 0) {
        setState(() {
          _games[idx].addAll(gc);
        });
        _maybeConnectSocketForGame(_games[idx]);
      }
    } catch (_) {
      // silenciar; la card seguirá con datos básicos
    }
  }

  void _maybeConnectSocketForGame(Map<String, dynamic> game) {
    final gameId = game['game_id'].toString();
    if (_sockets[gameId] != null) return; // ya conectado

    if (_getGameState(game) != _GameState.inProgress) return;

    final chRaw = (game['game_center_channel'] ?? game['rink_center_channel']);
    final String? channel = (chRaw is String && chRaw.trim().isNotEmpty) ? chRaw.trim() : null;
    if (channel == null) return;

    final socket = io.io(
      'https://sio.timetoscore.com/${channel}_$gameId',
      io.OptionBuilder()
        .setTransports(['websocket'])
        .disableAutoConnect()
        .setReconnectionAttempts(5)
        .setReconnectionDelay(500)
        .build(),
    );

    socket.on('clock', (data) async {
      final Map<String, dynamic> u = (data is String)
        ? (jsonDecode(data) as Map).map((k, v) => MapEntry(k.toString(), v))
        : Map<String, dynamic>.from(data as Map);

      if (!mounted || _loadGen == 0) return;

      _applyLightLiveUpdate(gameId, u);

      final mustRefetch = _shouldRefetchFromPacket(gameId, u);
      final firstSync = !_didSocketFirstSync.contains(gameId);

      if ((firstSync || mustRefetch) && !_fetchInFlight.contains(gameId)) {
        _fetchInFlight.add(gameId);
        _rememberTimestampsFromPacket(gameId, u);
        try {
          final gc = await _loadGameCenter(gameId);
          final idx = _games.indexWhere((g) => g['game_id'].toString() == gameId);
          if (idx >= 0 && mounted) {
            setState(() => _games[idx].addAll(gc));
            _reportHeightIfChanged();
          }
          _didSocketFirstSync.add(gameId);
        } finally {
          _fetchInFlight.remove(gameId);
        }
      }
    });

    socket.connect();
    _sockets[gameId] = socket;
  }

  void _disposeAllSockets() {
    for (final s in _sockets.values) {
      try { s?.off('clock'); } catch (_) {}
      try { s?.dispose(); } catch (_) {}
    }
    _sockets.clear();
    _lastEventsTs.clear();
    _lastRostersTs.clear();
    _didSocketFirstSync.clear();
    _fetchInFlight.clear();
  }

  Map<String, dynamic> _strKeyMap(dynamic v) {
    if (v is Map) {
      // Convierte cualquier tipo de llave a String de forma segura
      return v.map((k, val) => MapEntry(k?.toString() ?? '', val));
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _loadGameCenter(String gameId) async {
    try {
      final uri = ApiService.generateLink(
        'get_game_center',
        moreQueries: LinkedHashMap.of({
          'game_id': gameId,
          'widget': 'scoreboard'
          // TODO: Implement light argument when backend supports it  
          }),
      );
      final json = await ApiService.fetchData(uri);
      
      final gc = json['game_center'] as Map<String, dynamic>? ?? {};
      final gi = gc['game_info'] as Map<String, dynamic>? ?? {};
      final live = gc['live'];
      Map<String, dynamic> liveParsed = {};
      if (live is Map) {
        liveParsed = Map<String, dynamic>.from(live);
      }
      final rawPeriodList = liveParsed['period_list'] as List? ?? [];
      final periodList = rawPeriodList.map((p) => p?.toString()).toList();
      

      return {
        'game_center_status': gi['status']?.toString() ?? '',
        'formatted_date': gi['formatted_date']?.toString() ?? '',
        'display_time': gi['time']?.toString() ?? '',
        'boxscore_url': gi['boxscore_url']?.toString() ?? '',
        'scoresheet_url': gi['scoresheet_url']?.toString() ?? '',
        'game_center_channel': gi['game_channel']?.toString() ?? '',
        'rink_center_channel': gi['rink_channel']?.toString() ?? '',
        'goal_summary': liveParsed['goal_summary'] ?? {},
        'shot_summary': liveParsed['shot_summary'] ?? {},
        'misc_summary': liveParsed['misc_summary'] ?? {},
        'period_list': periodList,
        'events': liveParsed['events'] ?? {},
      };
    } catch (e) {
      return {};
    }
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return int.tryParse(s);
  }

  bool _shouldRefetchFromPacket(String gameId, Map<String, dynamic> u) {
    final le = _asInt(u['last_events']);
    final lr = _asInt(u['last_rosters']);

    if (le != null || lr != null) {
      final prevLe = _lastEventsTs[gameId];
      final prevLr = _lastRostersTs[gameId];
      final changed = (le != null && le != prevLe) || (lr != null && lr != prevLr);
      return changed;
    }
    final ev = u['events'];
    final ro = u['rosters'];
    final ev1 = ev == 1 || ev == '1';
    final ro1 = ro == 1 || ro == '1';
    return ev1 || ro1;
  }

  void _rememberTimestampsFromPacket(String gameId, Map<String, dynamic> u) {
    final le = _asInt(u['last_events']);
    final lr = _asInt(u['last_rosters']);
    if (le != null) _lastEventsTs[gameId]  = le;
    if (lr != null) _lastRostersTs[gameId] = lr;
  }

  void _applyLightLiveUpdate(String gameId, Map<String, dynamic> u) {
    final idx = _games.indexWhere((g) => g['game_id'].toString() == gameId);
    if (idx < 0) return;

    final g = _games[idx];
    final status = (g['game_center_status'] ?? g['game_status'] ?? '').toString().toUpperCase();
    final isFinal = status.contains('FINAL');

    int? hs = _asInt(u['homescore']);
    int? as_ = _asInt(u['awayscore']);
    if (!isFinal) {
      if (hs != null) g['home_goals'] = hs;
      if (as_ != null) g['away_goals'] = as_;
    }

    final p = (u['period'] ?? '').toString().trim();
    final c = (u['clock']  ?? '').toString().trim();
    if (p.isNotEmpty) g['live_period'] = p;
    if (c.isNotEmpty) g['live_clock']  = c;

    if (mounted) {
      setState(() { _games[idx] = g; });
      _reportHeightIfChanged();
    }
  }

  String _ordinal(int n) {
    if (n >= 11 && n <= 13) return '${n}th';
    switch (n % 10) {
      case 1: return '${n}st';
      case 2: return '${n}nd';
      case 3: return '${n}rd';
      default: return '${n}th';
    }
  }

  bool _isBreakPeriod(String raw) {
    final s = raw.toUpperCase();
    return s.contains('INTERMISSION') || s.contains('WARMUP');
  }

  String _periodFromSocketForDisplay(String raw) {
    final s = raw.trim().toUpperCase();

    final m = RegExp(r'^PERIOD\s+(\d+)$').firstMatch(s);
    if (m != null) {
      final n = int.tryParse(m.group(1)!);
      if (n != null) return '${_ordinal(n)} Period';
    }

    if (s == 'OT' || s == 'OVERTIME') return 'Overtime';
    final ot = RegExp(r'^OT(\d+)$').firstMatch(s);
    if (ot != null) {
      final n = int.tryParse(ot.group(1)!);
      if (n != null && n > 1) return '${n}OT';
      return 'Overtime';
    }

    if (s == 'SO' || s == 'SHOOTOUT') return 'Shootout';
    if (s.contains('INTERMISSION')) return 'Intermission';
    if (s.contains('WARMUP')) return 'Warmup';
    return s[0] + s.substring(1).toLowerCase();
  }

  _GameState _getGameState(Map<String, dynamic> game) {
    final status = (game['game_status'] ?? '').toString().toUpperCase();
    final centerStatus = (game['game_center_status'] ?? '').toString().toUpperCase();
    
    if (status == 'CLOSED' || centerStatus.contains('FINAL')) {
      return _GameState.completed;
    } else if (status == 'OPEN' || status == 'LIVE' || status == 'IN PROGRESS' || centerStatus.contains('PROGRESS' )) {
      return _GameState.inProgress;
    }
    return _GameState.pregame;
  }



  @override
  Widget build(BuildContext context) {
    _reportHeightIfChanged();
    
    return Scaffold(
      backgroundColor: tertiaryGrey.withOpacity(0.1),
      body: KeyedSubtree(
        key: _contentKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Daily Schedule & Scores',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: primaryBlue,
                      fontFamily: fontFamily,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildDateNavigation(),
                ],
              ),
            ),
            
            // Content
            _buildContent(MediaQuery.of(context).size.width < 600),
          ],
        ),
      ),
    );
  }

  void _goDay(int delta) {
    final next = _selectedDate.add(Duration(days: delta));
    setState(() {
      _selectedDate = next;
    });
    _fetchGames();
    _updateUrl();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged());
  }

  Future<void> _pickDate() async {
    final RenderBox? renderBox = _dateButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      final picked = await showDatePicker(
        context: context,
        initialDate: _selectedDate,
        firstDate: DateTime(2010),
        lastDate: DateTime(2100),
      );
      if (picked != null) {
        setState(() {
          _selectedDate = picked;
        });
        _fetchGames();
        _updateUrl();
        WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged());
      }
      return;
    }

    final offset = renderBox.localToGlobal(Offset.zero);
    
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2010),
      lastDate: DateTime(2100),
      anchorPoint: Offset(offset.dx + renderBox.size.width / 2, offset.dy + renderBox.size.height + 10),
    );
    
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
      });
      _fetchGames();
      _updateUrl();
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged());
    }
  }

  String _getFormattedDate(Map<String, dynamic> game) {
    final rawDate = (game['date'] ?? '').toString();
    try {
      final parsed = DateTime.parse(rawDate);
      return DateFormat('MMM dd, yyyy').format(parsed);
    } catch (_) {
      return rawDate;
    }
  }

  String _getFormattedTime(Map<String, dynamic> game) {
    final rawTime = (game['time'] ?? '').toString();
    try {
      final parts = rawTime.split(':');
      if (parts.length >= 2) {
        final hour = int.parse(parts[0]);
        final minute = parts[1];
        final amPm = hour >= 12 ? 'PM' : 'AM';
        final hour12 = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
        return '$hour12:$minute $amPm';
      }
      return rawTime;
    } catch (_) {
      return rawTime;
    }
  }

  String _getStatusText(Map<String, dynamic> game) {
    final state = _getGameState(game);

    switch (state) {
      case _GameState.completed:
        return game['result_string']?.toString() ?? 'Final';

      case _GameState.inProgress:
        final lp = (game['live_period'] ?? '').toString().trim();
        final lc = (game['live_clock']  ?? '').toString().trim();
        if (lp.isNotEmpty) {
          final label = _periodFromSocketForDisplay(lp);
          if (lc.isNotEmpty && !_isBreakPeriod(lp)) {
            return '$lc · $label';
          }
          return label;
        }

        final periodList = game['period_list'] as List? ?? [];
        if (periodList.isNotEmpty) {
          final p = periodList.last?.toString().toUpperCase();
          if (p == 'SO' || (p?.startsWith('SO') ?? false)) return 'Shootout';
          if (p == 'OT' || (p?.startsWith('OT') ?? false)) return 'Overtime';

          final n = int.tryParse(p ?? '');
          if (n == 1) return '1st Period';
          if (n == 2) return '2nd Period';
          if (n == 3) return '3rd Period';
          return game['game_status']?.toString() ?? 'In Progress';
        }
        return game['game_status']?.toString() ?? 'In Progress';

      case _GameState.pregame:
        final tz = game['timezn_ab']?.toString();
        final time = _getFormattedTime(game);
        return tz != null && tz.isNotEmpty ? '$time $tz' : time;
    }
  }

  Widget _buildGameStatusIndicator(Map<String, dynamic> game) {
    final state = _getGameState(game);
    
    switch (state) {
      case _GameState.completed:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: tertiaryGrey,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'FINAL',
            style: TextStyle(
              color: secondaryWhite,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              fontFamily: fontFamily,
            ),
          ),
        );
      case _GameState.inProgress:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: primaryRed,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'LIVE',
            style: TextStyle(
              color: secondaryWhite,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              fontFamily: fontFamily,
            ),
          ),
        );
      case _GameState.pregame:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: primaryBlue,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'UPCOMING',
            style: TextStyle(
              color: secondaryWhite,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              fontFamily: fontFamily,
            ),
          ),
        );
    }
  }

  Widget _buildDateNavigation() {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final isCompact = w < 420;
        final isTiny    = w < 340;
        final labelFmt = isTiny
            ? 'MMM d, yyyy'
            : (isCompact ? 'EEE, MMM d, yyyy' : 'EEEE, MMM dd, yyyy');
        final prevNextFmt = isTiny ? 'M/d' : 'MMM dd';

        final label = DateFormat(labelFmt).format(_selectedDate);
        final prev  = DateFormat(prevNextFmt).format(_selectedDate.subtract(const Duration(days: 1)));
        final next  = DateFormat(prevNextFmt).format(_selectedDate.add(const Duration(days: 1)));

        return Container(
          decoration: BoxDecoration(
            color: primaryBlue,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: textColor.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 12 : 16,
            vertical: isCompact ? 10 : 12,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: InkWell(
                  key: _dateButtonKey,
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: isCompact ? 10 : 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: secondaryWhite,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.calendar_today,
                          size: isCompact ? 16 : 18,
                          color: primaryBlue,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: primaryBlue,
                              fontWeight: FontWeight.w600,
                              fontFamily: fontFamily,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: () => _goDay(-1),
                    icon: Icon(Icons.chevron_left, color: secondaryWhite, size: isCompact ? 18 : 20),
                    label: Text(
                      prev,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(
                        color: secondaryWhite,
                        fontSize: isCompact ? 13 : 14,
                        fontFamily: fontFamily
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: () => _goDay(1),
                    icon: Text(
                      next,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(
                        color: secondaryWhite,
                        fontSize: isCompact ? 13 : 14,
                        fontFamily: fontFamily,
                      ),
                    ),
                    label: Icon(Icons.chevron_right, color: secondaryWhite, size: isCompact ? 18 : 20),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  String _getPeriodLabel(dynamic period) {
    final s = period?.toString().toUpperCase() ?? '';
    if (s == 'SO' || s.startsWith('SO')) return 'SO';
    if (s == 'OT' || s.startsWith('OT')) {
      final m = RegExp(r'^OT(\d+)$').firstMatch(s);
      if (m != null) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n > 1) return '${n}OT';
      }
      return 'OT';
    }
    final n = int.tryParse(s);
    switch (n) {
      case 1: return '1st';
      case 2: return '2nd';
      case 3: return '3rd';
      default:
        return n != null ? '$n' : s;
    }
  }

  int _getGoalsForPeriod(Map<String, dynamic> goals, dynamic period) {
    final key = period?.toString();
    if (key == null) return 0;
    var val = goals[key];

    if (val == null) {
      if (key == '4') val = goals['OT'] ?? goals['OT1'];
      if (key == '5') val = goals['SO'];
    }

    return int.tryParse((val ?? '0').toString()) ?? 0;
  }

  bool _hasGoalScorers(Map<String, dynamic> game) {
    dynamic eventsRaw = game['events'];
    
    if (eventsRaw is String) {
      try { eventsRaw = jsonDecode(eventsRaw); } catch (_) { return false; }
    }
    
    if (eventsRaw is Map) {
      for (final v in eventsRaw.values) {
        if (v is List && v.isNotEmpty) {
          for (final e in v) {
            if (e is Map) {
              final t = (e['type'] ?? e['event_type'] ?? '').toString().toLowerCase();
              if (t == 'goal' || t == 'g') return true;
            }
          }
        }
      }
    } else if (eventsRaw is List) {
      for (final e in eventsRaw) {
        if (e is Map) {
          final t = (e['type'] ?? e['event_type'] ?? '').toString().toLowerCase();
          if (t == 'goal' || t == 'g') return true;
        }
      }
    }
    
    return false;
  }

  Widget _buildGoalScorers(Map<String, dynamic> game) {
    final String homeName = (game['home_team'] ?? '').toString().trim();
    final String awayName = (game['away_team'] ?? '').toString().trim();
    final String homeId   = game['home_id']?.toString() ?? '';
    final String awayId   = game['away_id']?.toString() ?? '';

    final List<String> homeGoals = [];
    final List<String> awayGoals = [];

    dynamic eventsRaw = game['events'];

    // Si viniera como String JSON, intenta parsear
    if (eventsRaw is String) {
      try { eventsRaw = jsonDecode(eventsRaw); } catch (_) {}
    }

    // Funciones auxiliares para leer campos con nombres variables
    String pickPeriod(dynamic e, {String? fallback}) {
      final p = (e is Map ? (e['period'] ?? e['period_name'] ?? e['period_key']) : null)?.toString();
      return _getPeriodLabel(p ?? fallback);
    }

    String pickTime(dynamic e) {
      return (e is Map
        ? (e['time'] ?? e['goal_time'] ?? e['clock'] ?? '')
        : '').toString();
    }

    String pickPlayer(dynamic e) {
      return (e is Map
        ? (e['goal_player_name'] ?? e['scorer_name'] ?? e['player_name'] ?? '')
        : '').toString();
    }

    bool isGoal(dynamic e) {
      if (e is! Map) return false;
      final t = (e['type'] ?? e['event_type'] ?? '').toString().toLowerCase();
      return t == 'goal' || t == 'g'; // por si viniera abreviado
    }

    bool isHomeTeam(dynamic e) {
      if (e is! Map) return false;
      final teamName = (e['team_name'] ?? e['team'] ?? '').toString().trim();
      final teamId   = e['team_id']?.toString() ?? '';
      // Compara por id si existe, si no por nombre
      if (teamId.isNotEmpty && (homeId.isNotEmpty || awayId.isNotEmpty)) {
        if (homeId.isNotEmpty && teamId == homeId) return true;
        if (awayId.isNotEmpty && teamId == awayId) return false;
      }
      if (teamName.isNotEmpty && (homeName.isNotEmpty || awayName.isNotEmpty)) {
        if (teamName == homeName) return true;
        if (teamName == awayName) return false;
      }
      // Si no se puede determinar, asúmelo visitante para no mezclar con local
      return false;
    }

    void addGoal(dynamic e, {String? periodKey}) {
      if (!isGoal(e)) return;
      final player = pickPlayer(e);
      final time   = pickTime(e);
      if (player.isEmpty || time.isEmpty) return;
      final periodName = pickPeriod(e, fallback: periodKey);
      final goalText = '$player ($time $periodName)';
      if (isHomeTeam(e)) {
        homeGoals.add(goalText);
      } else {
        awayGoals.add(goalText);
      }
    }

    // Soporta: Map<String, List<Event>> (agrupado por periodo)
    if (eventsRaw is Map) {
      eventsRaw.forEach((k, v) {
        if (v is List) {
          for (final e in v) {
            addGoal(e, periodKey: k?.toString());
          }
        }
      });
    }
    // Soporta: List<Event> (lista plana)
    else if (eventsRaw is List) {
      for (final e in eventsRaw) {
        addGoal(e);
      }
    }
    // Nada que procesar
    else {
      return const SizedBox.shrink();
    }

    if (homeGoals.isEmpty && awayGoals.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tertiaryGrey.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Goal Scorers',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: primaryBlue,
              fontFamily: fontFamily,
            ),
          ),
          const SizedBox(height: 8),
          if (awayGoals.isNotEmpty) ...[
            RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 14, color: textColor, fontFamily: fontFamily),
                children: [
                  TextSpan(
                    text: '${game['away_team']}: ',
                    style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontFamily: fontFamily),
                  ),
                  TextSpan(text: awayGoals.join(', ')),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
          if (homeGoals.isNotEmpty) ...[
            RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 14, color: textColor, fontFamily: fontFamily),
                children: [
                  TextSpan(
                    text: '${game['home_team']}: ',
                    style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontFamily: fontFamily),
                  ),
                  TextSpan(text: homeGoals.join(', ')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openUrl(String url) {
    html.window.open(url, '_blank');
  }

  Widget _buildContent(isMobile) {
    if (_isLoadingSchedule && _games.isEmpty) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(primaryRed),
        ),
      );
    }

    if (_errorMessage != null) {
      return _buildErrorView();
    }

    if (_games.isEmpty) {
      return _buildEmptyView();
    }

    // Sin paginación: mostrar todos los juegos
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Lista de juegos
          ..._games.map((game) {
            return _buildGameCard(game, isMobile);
          }),
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: primaryRed,
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(color: textColor, fontFamily: fontFamily),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _fetchGames,
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryBlue,
              foregroundColor: secondaryWhite,
            ),
            child: Text('Retry', style: TextStyle(fontFamily: fontFamily)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.sports_hockey,
            size: 48,
            color: tertiaryGrey,
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'No games available for ${DateFormat('MMMM dd, yyyy').format(_selectedDate)}.',
              textAlign: TextAlign.center,
              style: TextStyle(color: textColor, fontFamily: fontFamily),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameCard(Map<String, dynamic> game, bool isMobile) {
    final state = _getGameState(game);
    
    // En móvil y juego completado, usar card con tabs
    if (isMobile && state == _GameState.completed) {
      return _GameCardWithTabs(
        game: game,
        state: state,
        colors: _GameCardColors(
          primaryRed: primaryRed,
          primaryBlue: primaryBlue,
          textColor: textColor,
          secondaryWhite: secondaryWhite,
          tertiaryGrey: tertiaryGrey,
          fontFamily: fontFamily,
        ),
        callbacks: _GameCardCallbacks(
          getFormattedDate: _getFormattedDate,
          getStatusText: _getStatusText,
          buildTeamRow: _buildTeamRow,
          buildScoringBreakdown: buildScoringBreakdown,
          buildGoalScorers: _buildGoalScorers,
          buildGameStatusIndicator: _buildGameStatusIndicator,
          buildActionButtons: _buildActionButtons,
          strKeyMap: _strKeyMap,
          hasGoalScorers: _hasGoalScorers,
        ),
        games: _games,
        seasonId: _seasonId,
      );
    }
    
    // Desktop o juegos no completados: card normal
    return _buildNormalGameCard(game, isMobile);
  }

  Widget _buildNormalGameCard(Map<String, dynamic> game, bool isMobile) {
    final state = _getGameState(game);
    //final gameId = game['game_id'].toString();
    final location = (game['location'] ?? '').toString();
    final awayTeam = (game['away_team'] ?? '').toString();
    final homeTeam = (game['home_team'] ?? '').toString();
    final awayLogo = game['away_smlogo']?.toString();
    final homeLogo = game['home_smlogo']?.toString();
    final awayId = game['away_id'].toString();
    final homeId = game['home_id'].toString();

    final goalSummary = _strKeyMap(game['goal_summary']);
    final homeGs = _strKeyMap(goalSummary['home_goals']);
    final awayGs = _strKeyMap(goalSummary['away_goals']);

    final homeGoals = (homeGs['total'] ?? game['home_goals'] ?? '0').toString();
    final awayGoals = (awayGs['total'] ?? game['away_goals'] ?? '0').toString();


    final homeGoalsInt = int.tryParse(homeGoals) ?? 0;
    final awayGoalsInt = int.tryParse(awayGoals) ?? 0;
    final homeWinner = homeGoalsInt > awayGoalsInt;
    final tie = homeGoals == awayGoals;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: secondaryWhite,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: textColor.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header con ubicación
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: primaryBlue,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    location,
                    style: TextStyle(
                      color: secondaryWhite,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      fontFamily: fontFamily,
                    ),
                  ),
                ),
                Text(
                  _getFormattedDate(game),
                  style: TextStyle(
                    color: secondaryWhite,
                    fontSize: 14,
                    fontFamily: fontFamily,
                  ),
                ),
              ],
            ),
          ),
          
          // Contenido del juego
          Padding(
            padding: EdgeInsets.all(isMobile ? 12 : 16),
            child: Column(
              children: [

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Away team
                          _buildTeamRow(
                            game,
                            logo: awayLogo,
                            name: awayTeam,
                            score: awayGoals,
                            teamId: awayId,
                            isWinner: !homeWinner && !tie,
                            isAway: true,
                            state: state,
                            isMobile: isMobile,
                          ),
                          
                          SizedBox(height: isMobile ? 12 : 16),
                          
                          // Home team
                          _buildTeamRow(
                            game,
                            logo: homeLogo,
                            name: homeTeam,
                            score: homeGoals,
                            teamId: homeId,
                            isWinner: homeWinner && !tie,
                            isAway: false,
                            state: state,
                            isMobile: isMobile,
                          ),
                        ],
                      ),
                    ),
                    if (state != _GameState.pregame && !isMobile) ...[
                      Expanded(child: buildScoringBreakdown(game)),
                    ],

                  ],
                ),
                
                // Scoring breakdown para juegos en vivo o finalizados
                if (isMobile) ...[
                  const SizedBox(height: 16),
                  buildScoringBreakdown(game),
                ],

                const SizedBox(height: 8),
                
                // Status y acciones
                Row(
                  children: [
                    _buildGameStatusIndicator(game),
                    SizedBox(width: isMobile ? 8 : 12),
                    Expanded(  
                      child: Text(
                        _getStatusText(game),
                        style: TextStyle(
                          fontSize: isMobile ? 12 : 14,  
                          fontWeight: state == _GameState.inProgress ? FontWeight.bold : FontWeight.normal,
                          color: state == _GameState.inProgress ? primaryRed : textColor,
                          fontFamily: fontFamily,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.visible,
                      ),
                    ),
                    SizedBox(width: isMobile ? 4 : 8),
                    _buildActionButtons(game, isMobile), 
                  ],
                ),
                
                if (state == _GameState.completed) ...[
                  const SizedBox(height: 8),
                  _buildGoalScorers(game),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTeamRow(
    Map<String, dynamic> game, {
    required String? logo,
    required String name,
    required String score,
    required String teamId,
    required bool isWinner,
    required bool isAway,
    required _GameState state,
    required bool isMobile,
  }) {
    // Calcular prioridad basada en el índice del juego en la lista
    final gameIndex = _games.indexOf(game);
    final priority = gameIndex >= 0 ? gameIndex : 999;
    
    return Row(
      mainAxisAlignment: isMobile ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.max,
      children: [
        Expanded(
          child: Row(
            children: [
              QueuedLogo(
                url: logo ?? '',
                size: isMobile ? 40 : 50,
                priority: priority,
              ),
              SizedBox(width: isMobile ? 8 : 12),
              Expanded(
                child: TextButton(
                  onPressed: () {
                    final cfg = js.context['widgetConfig'];
                    final targetPage = cfg['teamPage'] as String;
                    final uri = Uri(
                      path: targetPage,
                      queryParameters: {
                        'team': teamId,
                        if (_seasonId != null && _seasonId!.isNotEmpty)
                          'season': _seasonId!,
                      },
                    ).toString();
                    html.window.location.assign(uri);
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                  ),
                  child: Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: isMobile ? 16 : 18,
                      color: textColor,
                      fontFamily: fontFamily,
                    ),
                    textAlign: TextAlign.left,
                    softWrap: true,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: isMobile ? 4 : 8),
        Container(
          width: isMobile ? 35 : 40,
          height: 30,
          decoration: BoxDecoration(
            color: tertiaryGrey.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            score,
            style: TextStyle(
              fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
              fontSize: isMobile ? 18 : 20,
              color: state == _GameState.pregame ? tertiaryGrey : textColor,
              fontFamily: fontFamily,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons(Map<String, dynamic> game, bool isMobile) {
    final gameId = game['game_id'].toString();
    final boxscoreUrl = game['boxscore_url']?.toString() ?? '';
    final scoresheetUrl = game['scoresheet_url']?.toString() ?? '';
    final liveStream = game['live_stream']?.toString() ?? '';
    final liveLink = game['live_link']?.toString() ?? '';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (boxscoreUrl.isNotEmpty)
          _buildActionButton(
            icon: Icons.bar_chart,
            tooltip: 'Boxscore',
            onPressed: () => _openUrl(boxscoreUrl),
            isMobile: isMobile,
          ),
        
        if (scoresheetUrl.isNotEmpty) ...[
          const SizedBox(width: 8),
          _buildActionButton(
            icon: Icons.description,
            tooltip: 'Scoresheet',
            onPressed: () => _openUrl(scoresheetUrl),
            isMobile: isMobile,
          ),
        ],
        
        if (liveStream.isNotEmpty) ...[
          const SizedBox(width: 8),
          _buildActionButton(
            icon: Icons.live_tv,
            tooltip: 'Live Stream',
            color: primaryRed,
            onPressed: () => _openUrl(liveStream),
            isMobile: isMobile,
          ),
        ],
        
        if (liveLink.isNotEmpty) ...[
          const SizedBox(width: 8),
          _buildActionButton(
            icon: Icons.sports_hockey,
            tooltip: 'Game Center',
            color: primaryBlue,
            onPressed: () {
              final cfg = js.context['widgetConfig'];
              final targetPage = cfg['gameCenter'] as String;
              final uri = Uri(
                path: targetPage,
                queryParameters: {
                  'game_id': gameId,
                  if (_seasonId != null && _seasonId!.isNotEmpty)
                    'season': _seasonId!,
                },
              ).toString();
              html.window.location.assign(uri);
            },
            isMobile: isMobile,
          ),
        ],
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
    bool isMobile = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: EdgeInsets.all(isMobile ? 4 : 6),
          decoration: BoxDecoration(
            color: color ?? primaryBlue,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            icon,
            color: secondaryWhite,
            size: isMobile ? 16 : 18,
          ),
        ),
      ),
    );
  }

  String _formatPP(Map<String, dynamic> miscSummary, {required bool isHome}) {
    final side = isHome ? 'home' : 'away';
    int? goals;
    int? opp;

    int? asInt(dynamic v) {
      if (v == null) return null;
      return int.tryParse(v.toString());
    }

    void parseCombined(dynamic v) {
      if (v is String) {
        final m = RegExp(r'^\s*(\d+)\s*/\s*(\d+)\s*$').firstMatch(v);
        if (m != null) {
          goals ??= int.tryParse(m.group(1)!);
          opp   ??= int.tryParse(m.group(2)!);
        } else {
          opp ??= asInt(v);
        }
      } else if (v is num) {
        opp ??= v.toInt();
      } else if (v is Map) {
        goals ??= asInt(v['goals'] ?? v['pp_goals'] ?? v['ppg']);
        opp   ??= asInt(v['opportunities'] ?? v['pp_opportunities'] ?? v['ppo']);
      }
    }

    final dynamic ppRoot = miscSummary['pp'];
    if (ppRoot is Map) {
      parseCombined(ppRoot[side]);
    }

    parseCombined(miscSummary['${side}_pp']);

    goals ??= asInt(
        miscSummary['${side}_ppg'] ??
        miscSummary['${side}_pp_goals'] ??
        miscSummary['ppg_$side'] ??
        miscSummary['pp_goals_$side']
    );

    opp ??= asInt(
        miscSummary['${side}_ppo'] ??
        miscSummary['${side}_pp_opportunities'] ??
        miscSummary['pp_opportunities_$side'] ??
        miscSummary['ppo_$side']
    );

    if (goals == null && opp == null) return '—';
    return '${goals ?? 0}/${opp ?? 0}';
  }

  String _teamAbbr(Map<String, dynamic> game, {required bool isHome}) {
    final p = isHome ? 'home' : 'away';
    final raw = (game['${p}_ab'] ??
                game['${p}_abbr'] ??
                game['${p}_abbreviation'] ??
                game['${p}_team'])
                ?.toString()
                .trim() ?? '';

    if (raw.isEmpty) return isHome ? 'HOME' : 'AWAY';

    final up = raw.toUpperCase();
    return up.length <= 3 ? up : up.substring(0, 3);
  }

  Widget buildScoringBreakdown(Map<String, dynamic> game) {
    final goalSummary = _strKeyMap(game['goal_summary']);
    final shotSummary = _strKeyMap(game['shot_summary']);
    final miscSummary = _strKeyMap(game['misc_summary']);
    final periodList  = (game['period_list'] as List? ?? []).toList();

    if (goalSummary.isEmpty || periodList.isEmpty) return const SizedBox.shrink();

    final homeGoals = _strKeyMap(goalSummary['home_goals']);
    final awayGoals = _strKeyMap(goalSummary['away_goals']);
    final homeShots = _strKeyMap(shotSummary['home_shots']);
    final awayShots = _strKeyMap(shotSummary['away_shots']);

    const double teamColW = 170; // nombre del equipo
    const double statColW = 40;  // 1st, 2nd, 3rd, T, S
    const double ppColW   = 56;  // para valores tipo "12/23"

    final int pCount = periodList.length;
    final double tableMinW =
        teamColW + statColW * (pCount + 1) + ppColW + statColW; // equipo + periodos + T + PP + S

    TextStyle txt({bool bold=false, Color? color}) => TextStyle(
      fontFamily: fontFamily,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      color: color ?? textColor,
    );

    Widget cell(String v, {double w = statColW, bool bold = false, bool left = false}) {
      return SizedBox(
        width: w,
        child: Align(
          alignment: left ? Alignment.centerLeft : Alignment.center,
          child: Text(
            v,
            softWrap: false,                 
            overflow: TextOverflow.visible,
            style: txt(bold: bold),
          ),
        ),
      );
    }

    TableRow headerRow() => TableRow(
      decoration: BoxDecoration(color: primaryBlue.withOpacity(0.1)),
      children: [
        SizedBox(
          width: teamColW,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              'Scoring Summary',
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: txt(bold: true, color: primaryBlue),
            ),
          ),
        ),
        ...periodList.map((p) => cell(_getPeriodLabel(p), bold: true)),
        cell('T',  bold: true),
        cell('PP', bold: true, w: ppColW),
        cell('S',  bold: true),
      ],
    );

    TableRow awayRow() => TableRow(children: [
      SizedBox(width: teamColW, child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(_teamAbbr(game, isHome: false), softWrap: false, style: txt()),
      )),
      ...periodList.map((p) => cell(_getGoalsForPeriod(awayGoals, p).toString())),
      cell((awayGoals['total'] ?? '0').toString(), bold: true),
      cell(_formatPP(miscSummary, isHome: false), w: ppColW),
      cell((awayShots['total'] ?? '0').toString()),
    ]);

    TableRow homeRow() => TableRow(children: [
      SizedBox(width: teamColW, child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Text(_teamAbbr(game, isHome: true), softWrap: false, style: txt()),
      )),
      ...periodList.map((p) => cell(_getGoalsForPeriod(homeGoals, p).toString())),
      cell((homeGoals['total'] ?? '0').toString(), bold: true),
      cell(_formatPP(miscSummary, isHome: true), w: ppColW),
      cell((homeShots['total'] ?? '0').toString()),
    ]);

    return LayoutBuilder(
      builder: (context, constraints) {
        // Definir anchos de columnas para la tabla
        final columnWidths = <int, TableColumnWidth>{
          0: const FixedColumnWidth(teamColW),
          for (int i = 1; i <= pCount; i++) i: const FixedColumnWidth(statColW),
          pCount + 1: const FixedColumnWidth(statColW), // T
          pCount + 2: const FixedColumnWidth(ppColW),   // PP
          pCount + 3: const FixedColumnWidth(statColW), // S
        };

        final double tableW = math.max(constraints.maxWidth, tableMinW);

        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: tertiaryGrey.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: tableW,
                child: Table(
                  columnWidths: columnWidths,
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  border: TableBorder(
                    horizontalInside: BorderSide(color: tertiaryGrey.withOpacity(0.2)),
                  ),
                  children: [
                    headerRow(),
                    awayRow(),
                    homeRow(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

}

// Clases auxiliares para pasar datos al widget con tabs
class _GameCardColors {
  final Color primaryRed;
  final Color primaryBlue;
  final Color textColor;
  final Color secondaryWhite;
  final Color tertiaryGrey;
  final String fontFamily;

  _GameCardColors({
    required this.primaryRed,
    required this.primaryBlue,
    required this.textColor,
    required this.secondaryWhite,
    required this.tertiaryGrey,
    required this.fontFamily,
  });
}

class _GameCardCallbacks {
  final String Function(Map<String, dynamic>) getFormattedDate;
  final String Function(Map<String, dynamic>) getStatusText;
  final Widget Function(Map<String, dynamic>, {
    required String? logo,
    required String name,
    required String score,
    required String teamId,
    required bool isWinner,
    required bool isAway,
    required _GameState state,
    required bool isMobile,
  }) buildTeamRow;
  final Widget Function(Map<String, dynamic>) buildScoringBreakdown;
  final Widget Function(Map<String, dynamic>) buildGoalScorers;
  final Widget Function(Map<String, dynamic>) buildGameStatusIndicator;
  final Widget Function(Map<String, dynamic>, bool) buildActionButtons;
  final Map<String, dynamic> Function(dynamic) strKeyMap;
  final bool Function(Map<String, dynamic>) hasGoalScorers;

  _GameCardCallbacks({
    required this.getFormattedDate,
    required this.getStatusText,
    required this.buildTeamRow,
    required this.buildScoringBreakdown,
    required this.buildGoalScorers,
    required this.buildGameStatusIndicator,
    required this.buildActionButtons,
    required this.strKeyMap,
    required this.hasGoalScorers,
  });
}

// Widget con tabs para móvil (juegos completados)
class _GameCardWithTabs extends StatefulWidget {
  final Map<String, dynamic> game;
  final _GameState state;
  final _GameCardColors colors;
  final _GameCardCallbacks callbacks;
  final List<Map<String, dynamic>> games;
  final String? seasonId;

  const _GameCardWithTabs({
    required this.game,
    required this.state,
    required this.colors,
    required this.callbacks,
    required this.games,
    required this.seasonId,
  });

  @override
  State<_GameCardWithTabs> createState() => _GameCardWithTabsState();
}

class _GameCardWithTabsState extends State<_GameCardWithTabs> {
  int _selectedTab = 0;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final colors = widget.colors;
    final callbacks = widget.callbacks;
    
    final location = (game['location'] ?? '').toString();
    final awayTeam = (game['away_team'] ?? '').toString();
    final homeTeam = (game['home_team'] ?? '').toString();
    final awayLogo = game['away_smlogo']?.toString();
    final homeLogo = game['home_smlogo']?.toString();
    final awayId = game['away_id'].toString();
    final homeId = game['home_id'].toString();

    final goalSummary = callbacks.strKeyMap(game['goal_summary']);
    final homeGs = callbacks.strKeyMap(goalSummary['home_goals']);
    final awayGs = callbacks.strKeyMap(goalSummary['away_goals']);

    final homeGoals = (homeGs['total'] ?? game['home_goals'] ?? '0').toString();
    final awayGoals = (awayGs['total'] ?? game['away_goals'] ?? '0').toString();

    final homeGoalsInt = int.tryParse(homeGoals) ?? 0;
    final awayGoalsInt = int.tryParse(awayGoals) ?? 0;
    final homeWinner = homeGoalsInt > awayGoalsInt;
    final tie = homeGoals == awayGoals;

    final hasScorers = callbacks.hasGoalScorers(game);
    
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: colors.secondaryWhite,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: colors.textColor.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header compacto con ubicación y switch (solo si hay scorers)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: colors.primaryBlue,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        location,
                        style: TextStyle(
                          color: colors.secondaryWhite,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          fontFamily: colors.fontFamily,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        callbacks.getFormattedDate(game),
                        style: TextStyle(
                          color: colors.secondaryWhite.withOpacity(0.8),
                          fontSize: 9,
                          fontFamily: colors.fontFamily,
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasScorers) ...[
                  const SizedBox(width: 6),
                  // Switch compacto solo si hay scorers
                  _buildCompactSwitch(),
                ],
              ],
            ),
          ),
          
          // Contenido según tab seleccionado (sin padding extra)
          Padding(
            padding: const EdgeInsets.all(6),
            child: _selectedTab == 0 || !hasScorers
                ? _buildGameInfoTab(
                    game: game,
                    awayTeam: awayTeam,
                    homeTeam: homeTeam,
                    awayLogo: awayLogo,
                    homeLogo: homeLogo,
                    awayId: awayId,
                    homeId: homeId,
                    awayGoals: awayGoals,
                    homeGoals: homeGoals,
                    homeWinner: homeWinner,
                    tie: tie,
                  )
                : _buildGoalScorersTab(game: game),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactSwitch() {
    final colors = widget.colors;
    
    return Container(
      decoration: BoxDecoration(
        color: colors.secondaryWhite.withOpacity(0.2),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSwitchButton(
            icon: Icons.sports_hockey,
            isSelected: _selectedTab == 0,
            onTap: () => setState(() => _selectedTab = 0),
          ),
          _buildSwitchButton(
            icon: Icons.emoji_events,
            isSelected: _selectedTab == 1,
            onTap: () => setState(() => _selectedTab = 1),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchButton({
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colors = widget.colors;
    
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: isSelected ? colors.primaryRed : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Icon(
          icon,
          size: 16,
          color: colors.secondaryWhite,
        ),
      ),
    );
  }

  Widget _buildGameInfoTab({
    required Map<String, dynamic> game,
    required String awayTeam,
    required String homeTeam,
    required String? awayLogo,
    required String? homeLogo,
    required String awayId,
    required String homeId,
    required String awayGoals,
    required String homeGoals,
    required bool homeWinner,
    required bool tie,
  }) {
    final callbacks = widget.callbacks;
    final colors = widget.colors;
    final state = widget.state;
    
    return Column(
      children: [
        // Away team
        callbacks.buildTeamRow(
          game,
          logo: awayLogo,
          name: awayTeam,
          score: awayGoals,
          teamId: awayId,
          isWinner: !homeWinner && !tie,
          isAway: true,
          state: state,
          isMobile: true,
        ),
        
        const SizedBox(height: 4),
        
        // Home team
        callbacks.buildTeamRow(
          game,
          logo: homeLogo,
          name: homeTeam,
          score: homeGoals,
          teamId: homeId,
          isWinner: homeWinner && !tie,
          isAway: false,
          state: state,
          isMobile: true,
        ),
        
        const SizedBox(height: 6),
        
        // Scoring breakdown
        callbacks.buildScoringBreakdown(game),
        
        const SizedBox(height: 3),
        
        // Status y acciones (más compacto)
        Row(
          children: [
            callbacks.buildGameStatusIndicator(game),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                callbacks.getStatusText(game),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.normal,
                  color: colors.textColor,
                  fontFamily: colors.fontFamily,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 3),
            callbacks.buildActionButtons(game, true),
          ],
        ),
      ],
    );
  }
  Widget _buildGoalScorersTab({required Map<String, dynamic> game}) {
    return widget.callbacks.buildGoalScorers(game);
  }

}
