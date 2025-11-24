import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:season_standing_widget/img_job.dart';
import 'package:season_standing_widget/services/api_service.dart';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_util' as js_util;

class SortState {
  String column;
  bool ascending;

  SortState({required this.column, required this.ascending});
}

class _Col {
  final String label;
  final String key;
  final bool numeric;
  final bool sortable;
  const _Col(this.label, this.key, {this.numeric = true, this.sortable = true});
}

class SeasonStandingsWidget extends StatefulWidget {
  const SeasonStandingsWidget({super.key});

  @override
  State<SeasonStandingsWidget> createState() => _SeasonStandingsWidgetState();
}

class _SeasonStandingsWidgetState extends State<SeasonStandingsWidget> with TickerProviderStateMixin {
  Color primaryRed = const Color(0xFFdd1e36);
  Color primaryBlue = const Color(0xFF0c233f);
  Color textColor = const Color(0xFF000000);
  Color secondaryWhite = const Color(0xFFFFFFFF);
  Color tertiaryGrey = const Color(0xFF9ea1a6);
  String fontFamily = 'Roboto';

  late final String leagueId;
  late TabController _tabController;
  //late final ScrollController _scrollController;

  List<Map<String, String>> _seasons = [];
  String? _currentSeason;
  String? _selectedSeason;
  String? _levelId;
  Map<String, dynamic> _standingsRawData = {};
  List<Map<String, dynamic>> _teamsData = [];

  final Map<String, SortState> _sortStates = {};
  String? _lastSortColumn;
  bool?   _lastSortAscending;
  String? _errorMessage;

  List<Map<String, String>> _statClasses = [];
  String? _selectedStatClass;

  int _loadingOps = 0;
  bool get _isLoadingAny => _loadingOps > 0;

  void _beginLoad() => setState(() => _loadingOps++);
  void _endLoad()   => setState(() => _loadingOps = (_loadingOps - 1).clamp(0, 999));

  // === USPHL-only gating ===
  bool get _isUSPHLCreds => ApiService.apiUrl.toLowerCase().contains('usphl');
  bool get _isUSPHLLeague => const {'1','2','3'}.contains(leagueId);
  bool get _useUSPHLColumns => _isUSPHLCreds && _isUSPHLLeague;  

  bool _hasConferences = true;

  final List<_Col> _usphlBaseCols = const [
    _Col('GP','games_played'), 
    _Col('W','total_wins'), 
    _Col('L','losses'),
    _Col('OTL','otlosses'), 
    _Col('SOL','so_losses'),
    // (KRACH/SOS)
    _Col('PTS','pts'), 
    _Col('PTS%','pts_pct'),
    _Col('ROW','wins'), 
    _Col('OTW','otwins'), 
    _Col('SOW','so_wins'),
    _Col('GF','goals_for'), 
    _Col('GA','goals_against'),
    _Col('PP%','power_play_pct'), 
    _Col('PK%','penalty_kill_pct'),
    _Col('Streak','streak', numeric:false, sortable:false),
    _Col('P10','past_10', numeric:false, sortable:false),
    _Col('PIM','pims'),
  ];

  final GlobalKey _contentKey = GlobalKey();
  double _lastReportedHeight = 0;
  Timer? _heightReportTimer;

  List<_Col> get _usphlColsEffective {
    final list = List<_Col>.from(_usphlBaseCols);
    if (_showKrach) {
      final idxSol = list.indexWhere((c) => c.key == 'so_losses');
      final insertAt = idxSol >= 0 ? idxSol + 1 : 5; 
      list.insertAll(insertAt, const [
        _Col('KRACH', 'krach'),
        _Col('SOS',   'strength_of_schedule'),
      ]);
    }
    return list;
  }

  final Map<String, double> _mobileFixedColW = const {
    'games_played': 17,
    'total_wins': 17,
    'losses': 17,
    'ties': 17,
    'otwins': 17,
    'otlosses': 17,
    'so_losses': 17,
    'krach': 44,
    'strength_of_schedule': 44,
    'pts': 17,
    'win_pct': 44,          // 0.000
    'pts_pct': 44,          // 0.000
    'goals_for': 20,
    'goals_against': 20,
    'streak': 60,           // "W3"/"L10"
    'past_10': 60,          // "7-2-1"
    'power_play_pct': 44,   // 00.00
    'penalty_kill_pct': 44, // 00.00
    'pims': 44,
  };

  double _colW(String key) => _mobileFixedColW[key] ?? 48;

  // Widget _fixedBox({
  //   required bool enabled,
  //   required String key,
  //   required Widget child,
  // }) {
  //   if (!enabled) return child;
  //   return SizedBox(
  //     width: _colW(key), 
  //     child: Center(child: child)
  //   );
  // }

  Widget _minWidthBox({
    required String key,
    required Widget child,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: _colW(key)),
      child: Center(child: child),
    );
  }

  bool _computeShowKrach(Map<String, dynamic> raw) {
    const int kKrachBit = 0x00000008;
    final leagues = raw["leagues"] as List<dynamic>? ?? [];
    for (final league in leagues) {
      final maskStr = (league as Map)["stats2_mask"]?.toString() ?? "0";
      final mask = int.tryParse(maskStr) ?? 0;
      if ((mask & kKrachBit) == kKrachBit) return true;
    }
    return false;
  }

  String _fmt0(dynamic v) {
    if (v == null) return '-';
    final d = (v is num) ? v.toDouble() : double.tryParse(v.toString());
    if (d == null) return '-';
    return d.toStringAsFixed(0); 
  }

  num? _numOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v;
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    final cleaned = s.endsWith('%') ? s.substring(0, s.length - 1) : s;
    return num.tryParse(cleaned);
  }

  int _smartCompare(dynamic a, dynamic b) {
    final na = _numOrNull(a);
    final nb = _numOrNull(b);
    if (na != null && nb != null) {
      return na.compareTo(nb);
    }
    final sa = (a ?? '').toString();
    final sb = (b ?? '').toString();
    return sa.compareTo(sb);
  }

  String _fmtUSPHL(String key, dynamic raw) {
    if (raw == null) return '';
    switch (key) {
      case 'pts_pct':
        final d = (raw is num) ? raw.toDouble() : double.tryParse(raw.toString()) ?? 0;
        return d.toStringAsFixed(3);
      case 'power_play_pct':
      case 'penalty_kill_pct':
        final d = (raw is num) ? raw.toDouble() : double.tryParse(raw.toString()) ?? 0;
        return d.toStringAsFixed(2);
      case 'krach':
      case 'strength_of_schedule':
        final d = (raw is num) ? raw.toDouble() : double.tryParse(raw.toString()) ?? 0;
        return d.toStringAsFixed(0);
      default:
        return raw.toString();
    }
  }

  bool _showKrach = false;
  bool _imgCacheConfigured = false;

  @override
  void initState() {
    super.initState();
    //_scrollController = ScrollController();
    _loadCssVars();


    if(!_imgCacheConfigured) {
      ImageLoadScheduler.I.configureGlobalCache(entries: 24, bytesMB: 64);
      _imgCacheConfigured = true;
    }

    final uri = Uri.parse(html.window.location.href);
    _selectedSeason = uri.queryParameters['season'];
    final tabIndexFromUrl = int.tryParse(uri.queryParameters['tab'] ?? '') ?? 0;
  
    _lastSortColumn = uri.queryParameters['sortColumn'];
    if (uri.queryParameters['sortAscending'] != null) {
      _lastSortAscending = uri.queryParameters['sortAscending']!.toLowerCase() == 'true';
    }

    _levelId = uri.queryParameters['level_id'];
    leagueId = ApiService.defaultLeagueId;

    _fetchSeasons();
    _fetchStandingsData();
    _initTabControllerWithLength(
      3,
      initialIndex: (tabIndexFromUrl >= 0 && tabIndexFromUrl < 3) ? tabIndexFromUrl : 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged(immediate: true));
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
      tertiaryGrey = tg.isNotEmpty ? parseHex(tg) : const Color (0xFF9ea1a6);
      fontFamily = ff.isNotEmpty ? ff : 'Roboto';
    });
  }

  bool _isChangingTab = false;

  void _attachTabListener() {
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && !_isChangingTab) {
        _isChangingTab = true;

        try {
          if (js_util.hasProperty(js.context, '__resetFlutterContainerHeight')) {
            js.context.callMethod('__resetFlutterContainerHeight', const []);
          }
        } catch (_) {}
        
        setState(() {
          _lastReportedHeight = 0; 
          //_currentPage = 1;
        });
        
        _updateUrl(); 
        
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(milliseconds: 100), () {
            _reportHeightIfChanged(immediate: true);
            _isChangingTab = false;
          });
        });
      }
    });
  }

  void _initTabControllerWithLength(int length, {int initialIndex = 0}) {
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: initialIndex,
    );
    _attachTabListener();
  }

  bool _detectConferences(Map<String, dynamic> raw) {
    final leagues = raw["leagues"] as List<dynamic>? ?? [];
    for (final league in leagues) {
      final levels = (league as Map)["levels"] as List<dynamic>? ?? [];
      for (final level in levels) {
        final confs = (level as Map)["conferences"] as List<dynamic>? ?? [];
        if (confs.isEmpty) continue;
        final hasNamed = confs.any((c) {
          final m = (c as Map);
          final name = (m['name'] ?? m['conf_name'] ?? '').toString().trim();
          return name.isNotEmpty;
        });
        if (confs.length > 1 || hasNamed) {
          return true; 
        }
      }
    }
    return false; 
  }

  void _maybeRebuildTabsForConferences(bool newHasConferences) {
    if (_hasConferences == newHasConferences) return;

    final old = _tabController;
    final prevIndex = old.index;

    setState(() {
      _hasConferences = newHasConferences;
      final newLength = _hasConferences ? 3 : 2;

      int targetIndex = prevIndex;
      if (!_hasConferences && targetIndex == 1) targetIndex = 0;
      if (targetIndex >= newLength) targetIndex = newLength - 1;

      _initTabControllerWithLength(newLength, initialIndex: targetIndex);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());

    _updateUrl();
  }
  
  bool _heightScheduled = false;
  static const double _kMinDeltaForReport = 8.0;

  void _reportHeightIfChanged({bool immediate = false}) {
    if (!immediate && _heightScheduled) return;
    _heightReportTimer?.cancel();

    void doReport() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _contentKey.currentContext;
        final render = ctx?.findRenderObject();
        if (render is RenderBox) {
          final h = render.size.height;
          if ((h - _lastReportedHeight).abs() > _kMinDeltaForReport) {
            _lastReportedHeight = h;
            try { js.context.callMethod('setFlutterContainerHeight', [h]); } catch (_) {}
          }
        }
        _heightScheduled = false;
      });
    }

    if (immediate) {
      doReport();
    } else {
      _heightScheduled = true;
      _heightReportTimer = Timer(const Duration(milliseconds: 350), doReport);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _heightReportTimer?.cancel();
    super.dispose();
  }

  Map<String, String>? _getAdMediaConfig() {
    final container = html.document.getElementById('flutter-container');
    if (container == null) return null;

    final type = container.dataset['adType'];
    final src  = container.dataset['adSrc'];
    final link = container.dataset['adLink'];
    if (type == null || src == null) return null;

    return { 'type': type, 'src': src, if(link != null) 'link': link };
  }

  // Dummy ad Space:
  // Map<String, String>? _getAdMediaConfig() {
  //   final container = html.document.getElementById('flutter-container');
  //   if (container == null) {
  //     // Dummy return for testing
  //     return {
  //       'type': 'image',
  //       'src': 'https://via.placeholder.com/400x159.png?text=Ad+Banner',
  //       'link': 'https://example.com'
  //     };
  //   }

  //   final type = container.dataset['adType'];
  //   final src  = container.dataset['adSrc'];
  //   final link = container.dataset['adLink'];
  //   if (type == null || src == null) {
  //     // Dummy return for testing
  //     return {
  //       'type': 'image',
  //       'src': 'https://via.placeholder.com/400x159.png?text=Ad+Banner',
  //       'link': 'https://example.com'
  //     };
  //   }

  //   return { 'type': type, 'src': src, if(link != null) 'link': link };
  // }

  void _updateUrl() {
    final newParams = <String, String>{
      if (_selectedSeason != null && _selectedSeason != 'all')
        'season': _selectedSeason!,
      if (_selectedStatClass   != null) 'statClass': _selectedStatClass!,
      'tab': _tabController.index.toString(),
      if (_lastSortColumn != null)
      'sortColumn': _lastSortColumn!,
      if (_lastSortAscending != null)
        'sortAscending': _lastSortAscending.toString(),
      if (_levelId != null && _levelId!.isNotEmpty)
        'level_id': _levelId!,
    };
    final newUri = Uri(queryParameters: newParams).toString();
    html.window.history.replaceState(
      null,
      'Standings',
      newUri,
    );
  }

  void _applyInitialSortStates() {
    if (_lastSortColumn == null || _lastSortAscending == null) return;
    for (var grouping in ['level_name', 'conference_name', 'league_name']) {
      final groups = _groupBy(_teamsData, grouping).keys;
      for (var g in groups) {
        _sortStates[g] = SortState(
          column: _lastSortColumn!,
          ascending: _lastSortAscending!,
        );
      }
    }
  }

  Future<void> _fetchSeasons() async {
    _beginLoad();
    setState(() { _errorMessage = null; });

    try {
      final responseUri = ApiService.generateLink('get_leagues', moreQueries: {
        'league_id': leagueId,
      });
      final responseData = await ApiService.fetchData(responseUri);
      final List<dynamic> leaguesJson = responseData["leagues"] ?? [];

      if (leaguesJson.isEmpty) {
        throw Exception("No leagues returned from API");
      }

      final Map<String, dynamic> league = leaguesJson
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (l) => l["league_id"].toString() == leagueId,
          orElse: () => leaguesJson.first as Map<String, dynamic>,
        );

      _currentSeason = league['current_season']?.toString();
      _selectedSeason ??= _currentSeason;

      final List<dynamic> seasonsJson = league["seasons"] as List<dynamic>? ?? [];
      final loadedSeasons = seasonsJson.map<Map<String, String>>((s) {
        return {
          'id':   s['season_id'].toString(),
          'name': s['season_name'].toString(),
        };
      }).toList();

      final currentName = loadedSeasons
        .firstWhere(
          (s) => s['id'] == _currentSeason,
          orElse: () => {'name': ''},
        )['name'];

      final defaultTag = league["default_stat_class_tag"]?.toString();
      final List<dynamic> classesJson = league["stat_classes"] as List<dynamic>? ?? [];
      final loadedClasses = classesJson.map<Map<String, String>>((c) {
        return {
          'id':   c['stat_class_id'].toString(),
          'name': c['stat_class_name'].toString(),
        };
      }).toList();

      loadedClasses.sort((a, b) {
        if (a['id'] == defaultTag) return -1;
        if (b['id'] == defaultTag) return 1;
        return 0;
      });

      setState(() {
        _seasons = [
          if (_currentSeason != null)
            {'id': _currentSeason!, 'name': currentName ?? ''},
          ...loadedSeasons.where((s) => s['id'] != _currentSeason),
        ];

        _statClasses = loadedClasses;
        if (_statClasses.isNotEmpty) {
          _selectedStatClass ??= _statClasses.first['id'];
        } else {
          _selectedStatClass = null;
        }
      });

    } catch (e) {
      setState(() {
        _errorMessage = "Error fetching seasons: $e";
      });
    } finally {
      _endLoad();
    }
  }

  Future<void> _fetchStandingsData() async {
    _beginLoad();
    setState(() {
      _errorMessage = null;
      _teamsData = [];
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged(immediate: true));

    try {
      final responseUri = ApiService.generateLink('get_standings', moreQueries: {
        'league_id': leagueId,
        if (_selectedSeason != null && _selectedSeason != 'all')
          'season_id': _selectedSeason!,
          if(_selectedStatClass != null)
            'stat_class': _selectedStatClass!,
          if(_levelId != null && _levelId!.isNotEmpty)
            'level_id': _levelId!,
      });

      final responseData = await ApiService.fetchData(responseUri);
      _standingsRawData = responseData["standings"] ?? {};

      final krachFlag = _computeShowKrach(_standingsRawData);
      if (krachFlag != _showKrach) {
        setState(() => _showKrach = krachFlag);
      }
      if (_showKrach && _lastSortColumn == null && _sortStates.isEmpty) {
        _lastSortColumn = 'krach';
        _lastSortAscending = false;
      }

      final specialTeamsUri = ApiService.generateLink('get_special_teams_stats', moreQueries: {
        'league_id': leagueId,
        if (_selectedSeason != null && _selectedSeason != 'all')
          'season_id': _selectedSeason!,
        if(_selectedStatClass != null)
          'stat_class': _selectedStatClass!,
      });
      final specialTeamsData = await ApiService.fetchData(specialTeamsUri);
      List<dynamic> specialTeamsList = specialTeamsData["special_teams_stats"] ?? [];

      _teamsData = _parseStandings(_standingsRawData, specialTeamsList);

      final newHasConfs = _detectConferences(_standingsRawData);
      _maybeRebuildTabsForConferences(newHasConfs);

    } catch (e) {
      setState(() {
        _errorMessage = 'Error fetching standings: $e';
      });
    } finally {
      setState(() {
        if (_sortStates.isEmpty) {
          _applyInitialSortStates();
        }
        //_isLoading = false;
      });
      ImageLoadScheduler.I.clearAll();
      _endLoad();
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportHeightIfChanged(immediate: true));
    }
  }

  List<Map<String, dynamic>> _parseStandings(Map<String, dynamic> rawData, List<dynamic> specialTeamsList) {
    final List<Map<String, dynamic>> result = [];
    final Map<String, dynamic> specialTeamsMap = {};

    for (var st in specialTeamsList) {
      final tid = st["team_id"]?.toString() ?? "";
      specialTeamsMap[tid] = st;
    }

    final leagues = rawData["leagues"] as List<dynamic>? ?? [];
    for (var league in leagues) {
      final levels = league["levels"] as List<dynamic>? ?? [];
      for (var level in levels) {
        final conferences = level["conferences"] as List<dynamic>? ?? [];
        for (var conf in conferences) {
          final teams = conf["teams"] as List<dynamic>? ?? [];
          for (var t in teams) {
            final Map<String, dynamic> teamData = Map<String, dynamic>.from(t as Map);
            final tid = teamData["id"]?.toString() ?? "";

            if (specialTeamsMap.containsKey(tid)) {
              final stObj = specialTeamsMap[tid];
              teamData["power_play_pct"] = double.tryParse(stObj["power_play_pct"]?.toString() ?? "0") ?? 0.0;
              teamData["penalty_kill_pct"] = double.tryParse(stObj["penalty_kill_pct"]?.toString() ?? "0") ?? 0.0;
            } else {
              teamData["power_play_pct"] = 0.0;
              teamData["penalty_kill_pct"] = 0.0;
            }
            teamData["conference_name"] = conf["name"] ?? "";
            teamData["level_name"] = level["name"] ?? "";
            teamData["league_name"] = league["league_name"] ?? "";

            result.add(teamData);
          }
        }
      }
    }
    return result;
  }

  Map<String, List<Map<String, dynamic>>> _groupBy(List<Map<String, dynamic>> list, String groupKey) {
    final Map<String, List<Map<String, dynamic>>> map = {};
    for (var item in list) {
      final key = item[groupKey]?.toString() ?? '';
      map.putIfAbsent(key, () => []);
      map[key]!.add(item);
    }
    return map;
  }

  void _onSortForGroup(String groupName, String columnKey) {
    setState(() {
      final current = _sortStates[groupName] ?? SortState(column: 'pts', ascending: false);

      if (current.column == columnKey) {
        current.ascending = !current.ascending;
      } else {
        current.column = columnKey;
        current.ascending = true;
      }

      _sortStates[groupName] = current;
      _lastSortColumn     = columnKey;
      _lastSortAscending  = current.ascending;
      //_currentPage = 1; // Reset to first page on sort
    });
    _updateUrl();
    _reportHeightIfChanged(immediate: true);
  }
  
  @override
  Widget build(BuildContext context) {
    //_reportHeightIfChanged();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 900;
        final isNarrow = constraints.maxWidth < 400;

        ImageLoadScheduler.I.maxConcurrent = 3;

        final content = Column(
          key: _contentKey,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTopBarResponsive(isMobile, isNarrow),
            _buildActiveTabContent(isMobile, isNarrow),
          ],
        );

        return NotificationListener<OverscrollIndicatorNotification>(
          onNotification: (n) { n.disallowIndicator(); return true; },
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            clipBehavior: Clip.none,
            child: content,
          ),
        );
      },
    );
  }


  Widget _buildActiveTabContent(bool isMobile, bool isNarrow) {
    switch (_tabController.index) {
      case 0:
        return _buildStandingsContent("division", isMobile, isNarrow);
      case 1:
        if (_hasConferences) {
          return _buildStandingsContent("conference", isMobile, isNarrow);
        }
        return _buildStandingsContent("league", isMobile, isNarrow);
      case 2:
        return _buildStandingsContent("league", isMobile, isNarrow);
      default:
        return _buildStandingsContent("division", isMobile, isNarrow);
    }
  }

  Widget _buildTopBarResponsive(bool isMobile, bool isNarrow) {
    final adMedia = _getAdMediaConfig();

    return Container(
      color: secondaryWhite,
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 10 : 16,
        vertical: isMobile ? 6 : 8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          bool useVerticalLayout = constraints.maxWidth < 768;
          bool tabsNeedScroll = constraints.maxWidth < 500;
          
          if (useVerticalLayout) {
            return Column(
              children: [
                _buildScrollableTabBar(tabsNeedScroll),
                SizedBox(height: isMobile ? 6 : 8),
                if (adMedia != null) ... [
                  _buildAdSpace(adMedia, isMobile: true),
                  SizedBox(height: isMobile ? 6 : 8),
                ],
                Row(
                  children: [
                    Expanded(child: _buildSeasonDropdown(isMobile)),
                    SizedBox(width: isMobile ? 6 : 8),
                    Expanded(child: _buildStatClassDropdown(isMobile)),
                  ],
                ),
              ],
            );
          } else {
            return Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _buildScrollableTabBar(tabsNeedScroll),
                ),
                const SizedBox(width: 16),
                if (adMedia != null) ... [
                  Flexible(
                    flex: 2,
                    child: _buildAdSpace(adMedia, isMobile: false),
                  ),
                  const SizedBox(width: 16),
                ],
                _buildSeasonDropdown(false),
                const SizedBox(width: 16),
                _buildStatClassDropdown(false),
              ],
            );
          }
        },
      ),
    );
  }

  Widget _buildScrollableTabBar(bool needsScroll) {
    final tabs = <Tab>[
      const Tab(text: 'Division'),
      if (_hasConferences) const Tab(text: 'Conference'),
      const Tab(text: 'League'),
    ];

    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: { PointerDeviceKind.touch, PointerDeviceKind.mouse },
      ),
      child: TabBar(
        key: ValueKey<int>(tabs.length),
        isScrollable: needsScroll,
        controller: _tabController,
        labelColor: primaryRed,
        unselectedLabelColor: tertiaryGrey,
        indicatorColor: primaryRed,
        indicatorSize: TabBarIndicatorSize.label, 
        tabs: tabs,
      ),
    );
  }

  Widget _buildAdSpace(Map<String, dynamic> adMedia, {bool isMobile = false}) {
    final type = adMedia['type'] as String? ?? 'image';
    final src  = adMedia['src']  as String? ?? '';
    final link = adMedia['link'] as String?;
    final width  = isMobile ? null : 400.0;
    final height = isMobile ? 100.0 : 159.0;

    final adWidget = Container(
      width: width,
      height: height,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: tertiaryGrey.withOpacity(0.2),
        border: Border.all(color: Colors.black, width: 1.0),
        borderRadius: BorderRadius.circular(12.0),
        image: type == 'image'
            ? DecorationImage(
                image: NetworkImage(src),
                fit: BoxFit.cover,
                onError: (_, __) {},
              )
            : null,
      ),
      child: type == 'video'
          ? HtmlElementView(viewType: 'ad-video-$src')
          : null,
    );

    return link != null
      ? MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              html.window.open(link, '_blank');
            },
            child: adWidget,
          ),
        )
      : adWidget;
  }

  Widget _buildSeasonDropdown(bool isMobile) {
    return Container(
      width: 150,
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(isMobile ? 6 : 8),
        border: Border.all(color: tertiaryGrey),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedSeason,
          hint: Text('Select Season', style: TextStyle(fontSize: isMobile ? 12 : 14)),
          isExpanded: true,
          icon: Icon(Icons.arrow_drop_down, color: primaryBlue, size: isMobile ? 20 : 24),
          items: _seasons.map((Map<String, String> item) {
            return DropdownMenuItem<String>(
              value: item['id'],
              child: Text(item['name'] ?? '', style: TextStyle(fontSize: isMobile ? 12 : 14)),
            );
          }).toList(),
          onChanged: (val) async {
            setState(() {
              _selectedSeason = val;
            });
            await _fetchStandingsData();
            _updateUrl();
          },
          style: TextStyle(
            color: textColor,
            fontSize: isMobile ? 12 : 14,
            fontFamily: fontFamily,
          ),
        ),
      ),
    );
  }

  Widget _buildStatClassDropdown(bool isMobile) {
    return Container(
      width: 150,
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(isMobile ? 6 : 8),
        border: Border.all(color: tertiaryGrey)
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedStatClass,
          hint: Text('Class', style: TextStyle(fontSize: isMobile ? 12 : 14)),
          isExpanded: true,
          icon: Icon(Icons.arrow_drop_down, color: primaryBlue, size: isMobile ? 20 : 24),
          items: _statClasses.map((item) {
            return DropdownMenuItem<String>(
              value: item['id'],
              child: Text(item['name'] ?? '', style: TextStyle(fontSize: isMobile ? 12 : 14)),
            );
          }).toList(),
          onChanged: (val) async {
            setState(() => _selectedStatClass = val);
            await _fetchStandingsData();
            _updateUrl();
          },
          style: TextStyle(
            color: textColor,
            fontSize: isMobile ? 12 : 14,
            fontFamily: fontFamily,
          ),
        )      
      )
    );
  }

  Widget _buildStandingsContent(String viewType, bool isMobile, bool isNarrow) {
    if (_isLoadingAny) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(primaryRed),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          style: TextStyle(color: primaryRed, fontFamily: fontFamily,),
        ),
      );
    }

    if (_teamsData.isEmpty) {
      return Center(
        child: Text(
          'No standings data available.',
          style: TextStyle(color: textColor, fontFamily: fontFamily,),
        ),
      );
    }

    Map<String, List<Map<String, dynamic>>> groupedData = {};
    if (viewType == "division") {
      groupedData = _groupBy(_teamsData, 'level_name');
    } else if (viewType == "conference") {
      groupedData = _groupBy(_teamsData, 'conference_name');
    } else {
      groupedData = _groupBy(_teamsData, 'league_name');
    }

    groupedData.forEach((groupName, teams) {
      final sortState = _sortStates[groupName] ?? SortState(column: 'pts', ascending: false);
      teams.sort((a, b) {
        final cmp = _smartCompare(a[sortState.column], b[sortState.column]);
        return sortState.ascending ? cmp : -cmp;
      });
    });

    final allGroups = groupedData.entries.toList();

    final useFixedMobileW = isMobile && viewType == "conference";

    // if (isMobile) {
    if (isMobile) {
      return Container(
        color: secondaryWhite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: groupedData.entries.map((entry) {
            final groupName = entry.key.isEmpty ? '' : entry.key;
            final teams = entry.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                  color: primaryBlue.withOpacity(0.1),
                  child: Text(
                    groupName,
                    style: TextStyle(
                      color: primaryBlue,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      fontFamily: fontFamily,
                    ),
                  ),
                ),
                _useUSPHLColumns
                  ? _buildMobileStandingsTableUSPHL(teams, isNarrow, groupName, fixedWidths: useFixedMobileW, useFixedMobileW: useFixedMobileW)
                  : _buildMobileStandingsTable(teams, isNarrow, groupName, fixedWidths: useFixedMobileW, useFixedMobileW: useFixedMobileW),
              ],
            );
          }).toList(),
        ),
      );
    } else {
      return Container(
        color: secondaryWhite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: allGroups.map((entry) {
            final groupName = entry.key.isEmpty ? '' : entry.key;
            final teams = entry.value; 

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  color: primaryBlue.withOpacity(0.1),
                  child: Text(groupName, style: TextStyle(color: primaryBlue, fontSize: 16, fontWeight: FontWeight.bold, fontFamily: fontFamily)),
                ),
                _useUSPHLColumns
                    ? _buildTableHeaderUSPHL(groupName)
                    : _buildTableHeader(groupName),
                ...teams.map((team) {
                  final index = teams.indexOf(team); 
                  return _useUSPHLColumns
                      ? _buildTeamRowUSPHL(team, index)
                      : _buildTeamRow(team, index);
                }),
              ],
            );
          }).toList(),
        ),
      );
    }
  }

  Widget _buildMobileStandingsTable(
    List<Map<String, dynamic>> teams, 
    bool isNarrow, 
    String groupName, 
    {int rankOffset = 0,
    bool fixedWidths = false,
    bool useFixedMobileW = false,
    }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          color: secondaryWhite,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(primaryBlue),
            headingTextStyle: TextStyle(
              color: secondaryWhite,
              fontWeight: FontWeight.bold,
              fontSize: 14,
              fontFamily: fontFamily,
            ),
            columnSpacing: 8,
            horizontalMargin: 8,
            columns: [
              DataColumn(
                label: Center(
                  child: Text('Pos',
                    style: TextStyle(
                      color: secondaryWhite,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      fontFamily: fontFamily,
                    ),
                  ),
                ),
              ),
              DataColumn(
                label: Text(' ',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    fontFamily: fontFamily,
                  ),
                ),
              ),
              DataColumn(
                headingRowAlignment: MainAxisAlignment.center,
                label: _buildSortableMobileHeaderCell(
                  'Team',
                  'team_name',
                  groupName,
                ),
              ),
            ],
            rows: List.generate(teams.length, (index) {
              final team = teams[index];
              final teamId = team['id'].toString();
              final position = rankOffset +  index + 1;
              final teamName = team["team_name"]?.toString() ?? "";
              return DataRow(
                color: WidgetStateProperty.resolveWith((states) {
                  return index % 2 == 0
                    ? secondaryWhite
                    : tertiaryGrey.withOpacity(0.05);
                }),
                cells: [
                  DataCell(
                    Center(
                      child: Text(
                        position.toString(),
                        style: TextStyle(fontSize: 14, fontFamily: fontFamily,),
                      ),
                    ),
                  ),

                  // Logo Cell
                  DataCell(
                    Center(
                      child: QueuedLogo(
                        url: team["smlogo"]?.toString() ?? "",
                        size: 35,
                        priority: index,
                      ),
                    ),
                  ),

                  DataCell(
                    SizedBox(
                      width: isNarrow ? 100 : 150,
                      child: TextButton(
                        style: ButtonStyle(
                          padding: WidgetStateProperty.all(EdgeInsets.zero),
                          minimumSize: WidgetStateProperty.all(Size.zero),  
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {
                          final cfg = js.context['widgetConfig'];
                          final targetPage = cfg['teamPage'] as String;
                          final uri = Uri(
                            path: targetPage,
                            queryParameters: {
                              "team": teamId,
                              if(_selectedSeason != null && _selectedSeason != 'all')
                                "season": _selectedSeason,
                            }
                          ).toString();
                          html.window.location.assign(uri);
                        },
                        child: Text(
                          textAlign: TextAlign.start,
                          maxLines: 2,
                          overflow: TextOverflow.visible,
                          softWrap: true,
                          teamName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: textColor,
                            fontFamily: fontFamily,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
    
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(primaryBlue),
              headingTextStyle: TextStyle(
                color: secondaryWhite,
                fontWeight: FontWeight.bold,
                fontSize: 14,
                fontFamily: fontFamily,
              ),
              columnSpacing: 8,
              horizontalMargin: 8,
              columns: [
                DataColumn(
                  label: useFixedMobileW 
                    ? _minWidthBox(key: 'games_played', child: _buildSortableMobileHeaderCell('GP', 'games_played', groupName))
                    : _buildSortableMobileHeaderCell('GP', 'games_played', groupName),
                  numeric: true,
                ),
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'total_wins', child: _buildSortableMobileHeaderCell('W', 'total_wins', groupName))
                    : _buildSortableMobileHeaderCell('W', 'total_wins', groupName),
                  numeric: true,
                ),
                DataColumn(
                  label: 
                  useFixedMobileW
                    ? _minWidthBox(key: 'losses', child: _buildSortableMobileHeaderCell('L', 'losses', groupName))
                    : _buildSortableMobileHeaderCell('L', 'losses', groupName),
                  numeric: true,
                ),
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'ties', child: _buildSortableMobileHeaderCell('T', 'ties', groupName))
                    : _buildSortableMobileHeaderCell('T', 'ties', groupName),
                  numeric: true,
                ),
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'otwins', child: _buildSortableMobileHeaderCell('OTW', 'otwins', groupName))
                    : _buildSortableMobileHeaderCell('OTW', 'otwins', groupName),
                  numeric: true,
                ),             
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'otlosses', child: _buildSortableMobileHeaderCell('OTL', 'otlosses', groupName))
                    : _buildSortableMobileHeaderCell('OTL', 'otlosses', groupName),
                  numeric: true,
                ),
                
                if (_showKrach) ...[
                  DataColumn(
                    label: useFixedMobileW
                      ? _minWidthBox(key: 'krach', child: _buildSortableMobileHeaderCell('KRACH', 'krach', groupName))
                      : _buildSortableMobileHeaderCell('KRACH', 'krach', groupName),
                    numeric: true,
                  ),
                  DataColumn(
                    label: useFixedMobileW
                      ? _minWidthBox(key: 'strength_of_schedule', child: _buildSortableMobileHeaderCell('SOS', 'strength_of_schedule', groupName))
                      : _buildSortableMobileHeaderCell('SOS', 'strength_of_schedule', groupName),
                    numeric: true,
                  ),
                ],
                
                if(leagueId != '5')
                  DataColumn(
                    label: useFixedMobileW
                      ? _minWidthBox(key: 'pts', child: _buildSortableMobileHeaderCell('PTS', 'pts', groupName))
                      : _buildSortableMobileHeaderCell('PTS', 'pts', groupName),
                    numeric: true,
                  ),
                
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'win_pct', child: _buildSortableMobileHeaderCell('WIN%', 'win_pct', groupName))
                    : _buildSortableMobileHeaderCell('WIN%', 'win_pct', groupName),
                  numeric: true,
                ),
                
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'pts_pct', child: _buildSortableMobileHeaderCell('PTS%', 'pts_pct', groupName))
                    : _buildSortableMobileHeaderCell('PTS%', 'pts_pct', groupName),
                  numeric: true,
                ),
                
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'goals_for', child: _buildSortableMobileHeaderCell('GF', 'goals_for', groupName))
                    : _buildSortableMobileHeaderCell('GF', 'goals_for', groupName),
                  numeric: true,
                ),
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'goals_against', child: _buildSortableMobileHeaderCell('GA', 'goals_against', groupName))
                    : _buildSortableMobileHeaderCell('GA', 'goals_against', groupName),
                  numeric: true,
                ),
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'streak', child: Text('Streak', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily)))
                    : Text('Streak', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily)),
                ),
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'past_10', child: Text('P10', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily)))
                    : Text('P10', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily)),
                ),
                
                if (leagueId != '5') ...[
                  DataColumn(
                    label: useFixedMobileW
                      ? _minWidthBox(key: 'power_play_pct', child: _buildSortableMobileHeaderCell('PP%', 'power_play_pct', groupName))
                      : _buildSortableMobileHeaderCell('PP%', 'power_play_pct', groupName),
                    numeric: true,
                  ),
                  DataColumn(
                    label: useFixedMobileW
                      ? _minWidthBox(key: 'penalty_kill_pct', child: _buildSortableMobileHeaderCell('PK%', 'penalty_kill_pct', groupName))
                      : _buildSortableMobileHeaderCell('PK%', 'penalty_kill_pct', groupName),
                    numeric: true,
                  ),
                ],
                
                DataColumn(
                  label: useFixedMobileW
                    ? _minWidthBox(key: 'pims', child: _buildSortableMobileHeaderCell('PIM', 'pims', groupName))
                    : _buildSortableMobileHeaderCell('PIM', 'pims', groupName),
                  numeric: true,
                ),
              ],
              rows: List.generate(teams.length, (index) {
                final team = teams[index];
                final gp = team["games_played"] ?? 0;
                final w = team["total_wins"] ?? 0;
                final l = team["losses"] ?? 0;
                final t = team["ties"] ?? 0;
                final otw = team["otwins"] ?? 0;
                final otl = team["otlosses"] ?? 0;
                final pts = team["pts"] ?? 0;
                final pct = double.tryParse(team["win_pct"]?.toString() ?? "0") ?? 0;
                final pts_pct = double.tryParse(team["pts_pct"]?.toString() ?? "0") ?? 0;
                final gf = team["goals_for"] ?? 0;
                final ga = team["goals_against"] ?? 0;
                final streak = team["streak"]?.toString() ?? "";
                final past10 = team["past_10"]?.toString() ?? "";
                final pp = team["power_play_pct"] ?? 0;
                final pk = team["penalty_kill_pct"] ?? 0;
                final pim = team["pims"] ?? 0;
                
                return DataRow(
                  color: WidgetStateProperty.resolveWith((states) {
                    return index % 2 == 0
                      ? secondaryWhite
                      : tertiaryGrey.withOpacity(0.05);
                  }),
                  cells: [
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'games_played', child: Text(gp.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(gp.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'total_wins', child: Text(w.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(w.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'losses', child: Text(l.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(l.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'ties', child: Text(t.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(t.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),  
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'otwins', child: Text(otw.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(otw.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),                      
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'otlosses', child: Text(otl.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(otl.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                    if (_showKrach) ...[
                      DataCell(
                        useFixedMobileW
                          ? _minWidthBox(key: 'krach', child: Text(_fmt0(team['krach']), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                          : Center(child: Text(_fmt0(team['krach']), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                      ),
                      DataCell(
                        useFixedMobileW
                          ? _minWidthBox(key: 'strength_of_schedule', child: Text(_fmt0(team['strength_of_schedule']), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                          : Center(child: Text(_fmt0(team['strength_of_schedule']), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                      ),
                    ],
                
                    if(leagueId != '5')
                      DataCell(
                        useFixedMobileW
                          ? _minWidthBox(key: 'pts', child: Text(pts.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                          : Center(child: Text(pts.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                      ),
                    
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'win_pct', child: Text(pct.toStringAsFixed(3), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(pct.toStringAsFixed(3), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'pts_pct', child: Text(pts_pct.toStringAsFixed(3), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(pts_pct.toStringAsFixed(3), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'goals_for', child: Text(gf.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(gf.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'goals_against', child: Text(ga.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(ga.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'streak', child: Text(streak, style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(streak, style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'past_10', child: Text(past10, style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(past10, style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                      
                    if (leagueId != '5') ...[ 
                      DataCell(
                        useFixedMobileW
                          ? _minWidthBox(key: 'power_play_pct', child: Text("${pp.toStringAsFixed(2)}", style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                          : Center(child: Text("${pp.toStringAsFixed(2)}", style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                      ),
                      DataCell(
                        useFixedMobileW
                          ? _minWidthBox(key: 'penalty_kill_pct', child: Text("${pk.toStringAsFixed(2)}", style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                          : Center(child: Text("${pk.toStringAsFixed(2)}", style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                      ),
                    ],
                    DataCell(
                      useFixedMobileW
                        ? _minWidthBox(key: 'pims', child: Text(pim.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
                        : Center(child: Text(pim.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily))),
                    ),
                  ],
                );
              }),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSortableMobileHeaderCell(String label, String columnKey, String groupName,) {
    final sortState = _sortStates[groupName];
    final isActive = (sortState != null && sortState.column == columnKey);
    final icon = isActive
      ? (sortState.ascending ? Icons.arrow_drop_up : Icons.arrow_drop_down)
      : null;

    return InkWell(
      onTap: () => _onSortForGroup(groupName, columnKey),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label,
            style: TextStyle(
              color: secondaryWhite,
              fontWeight: FontWeight.bold,
              fontSize: 14,
              fontFamily: fontFamily,
            ),
          ),
          if (icon != null) ...[
            const SizedBox(width: 2),
            Icon(
              icon,
              color: secondaryWhite,
              size: 18,
            ),
          ]
        ],
      ),
    );
  }

  Widget _buildMobileStandingsTableUSPHL(
    List<Map<String, dynamic>> teams, 
    bool isNarrow, 
    String groupName, 
    {int rankOffset = 0,
    bool fixedWidths = false,
    useFixedMobileW = false,
    }) {
    
    final leftTable = DataTable(
      headingRowColor: WidgetStateProperty.all(primaryBlue),
      headingTextStyle: TextStyle(
        color: secondaryWhite, fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily,
      ),
      columnSpacing: 8,
      horizontalMargin: 8,
      columns: [
        DataColumn(
          label: Center(
            child: Text('Pos', style: TextStyle(color: secondaryWhite, fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily)),
          ),
        ),
        const DataColumn(label: Text(' ')),
        DataColumn(
          label: _buildSortableMobileHeaderCell('Team', 'team_name', groupName),
        ),
      ],
      rows: List.generate(teams.length, (index) {
        final team = teams[index];
        final teamId = team['id']?.toString() ?? '';
        final position = rankOffset + index + 1;
        final teamName = team['team_name']?.toString() ?? '';
        return DataRow(
          color: WidgetStateProperty.resolveWith((states) => index % 2 == 0 ? secondaryWhite : tertiaryGrey.withOpacity(0.05)),
          cells: [
            DataCell(Center(child: Text(position.toString(), style: TextStyle(fontSize: 14, fontFamily: fontFamily)))),

            // Logo Cell
            DataCell(
              Center(
                child: QueuedLogo(
                  url: team["smlogo"]?.toString() ?? "",
                  size: 35,
                  priority: index,
                ),
              ),
            ),

            DataCell(SizedBox(
              width: isNarrow ? 100 : 150,
              child: TextButton(
                style: ButtonStyle(
                  padding: WidgetStateProperty.all(EdgeInsets.zero),
                  minimumSize: WidgetStateProperty.all(Size.zero),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  alignment: Alignment.centerLeft,
                ),
                onPressed: () {
                  final cfg = js.context['widgetConfig'];
                  final targetPage = cfg['teamPage'] as String;
                  final uri = Uri(
                    path: targetPage,
                    queryParameters: {
                      "team": teamId,
                      if(_selectedSeason != null && _selectedSeason != 'all') "season": _selectedSeason,
                      if(_levelId != null && _levelId!.isNotEmpty) "level_id": _levelId,
                    }
                  ).toString();
                  html.window.location.assign(uri);
                },
                child: Text(
                  teamName, 
                  textAlign: TextAlign.start,
                  maxLines: 2,
                  overflow: TextOverflow.visible,
                  softWrap: true,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: textColor, fontFamily: fontFamily),
                ),
              ),
            )),
          ],
        );
      }),
    );

    // final rightColumns = _usphlColsEffective.map((c) {
    //   if (c.sortable) {
    //     return DataColumn(
    //       label: _buildSortableMobileHeaderCell(c.label, c.key, groupName),
    //       numeric: c.numeric,
    //     );
    //   } else {
    //     return DataColumn(
    //       label: Text(c.label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily)),
    //       numeric: c.numeric,
    //     );
    //   }
    // }).toList();
    final rightColumns = _usphlColsEffective.map((c) {
      final header = c.sortable
        ? _buildSortableMobileHeaderCell(c.label, c.key, groupName)
        : Text(c.label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily));

      return DataColumn(
        label: fixedWidths
          ? _minWidthBox(key: c.key, child: header)
          : header,
        numeric: c.numeric,
      );
    }).toList();

    final rightRows = List.generate(teams.length, (index) {
      final team = teams[index];
      return DataRow(
        color: WidgetStateProperty.resolveWith((states) => index % 2 == 0 ? secondaryWhite : tertiaryGrey.withOpacity(0.05)),
        cells: _usphlColsEffective.map((c) {
          final raw = team[c.key] ?? (c.numeric ? 0 : '');
          final v = _fmtUSPHL(c.key, raw);
          return DataCell(
            fixedWidths
              ? _minWidthBox(key: c.key, child: Text(v, style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
              : Center(child: Text(v, style: TextStyle(fontSize: 14, fontFamily: fontFamily)))
          );
        }).toList(),
      );
    });

    final rightTable = DataTable(
      headingRowColor: WidgetStateProperty.all(primaryBlue),
      headingTextStyle: TextStyle(
        color: secondaryWhite, fontWeight: FontWeight.bold, fontSize: 14, fontFamily: fontFamily,
      ),
      columnSpacing: 8,
      horizontalMargin: 8,
      columns: rightColumns,
      rows: rightRows,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(color: secondaryWhite, child: leftTable),
        Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: rightTable)),
      ],
    );
  }

  Widget _buildTableHeader(String groupName) {
    final headerStyle = TextStyle(
      color: secondaryWhite,
      fontWeight: FontWeight.bold,
      fontSize: 12,
      fontFamily: fontFamily,
    );

    return Container(
      color: primaryBlue,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          _buildHeaderCell('#', flex: 1, style: headerStyle),
          _buildHeaderCell('', flex: 2, style: headerStyle),
          _buildSortableHeaderCell(
            'Team Name',
            'team_name',
            flex: 5,
            style: headerStyle,
            groupName: groupName,
          ),
          _buildSortableHeaderCell(
            'GP',
            'games_played',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),
          _buildSortableHeaderCell(
            'W',
            'total_wins',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),
          _buildSortableHeaderCell(
            'L',
            'losses',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),
          
          _buildSortableHeaderCell(
            'T',
            'ties',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),

          _buildSortableHeaderCell(
            'OTW',
            'otwins',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),
//
          _buildSortableHeaderCell(
            'OTL',
            'otlosses',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),

          if (_showKrach) ...[
            _buildSortableHeaderCell(
              'KRACH', 
              'krach', 
              flex: 3, 
              style: headerStyle, 
              groupName: groupName
            ),

            _buildSortableHeaderCell(
              'SOS',   
              'strength_of_schedule', 
              flex: 3, 
              style: headerStyle, 
              groupName: groupName
            ),
          ],

          if(leagueId != '5')
            _buildSortableHeaderCell(
              'PTS',
              'pts',
              flex: 2,
              style: headerStyle,
              groupName: groupName,
            ),


          _buildSortableHeaderCell(
            'WIN%',
            'win_pct',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),

          _buildSortableHeaderCell(
            'PTS%',
            'pts_pct',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),

          _buildSortableHeaderCell(
            'GF',
            'goals_for',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),
          _buildSortableHeaderCell(
            'GA',
            'goals_against',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),
          _buildHeaderCell('Streak', flex: 3, style: headerStyle),
          _buildHeaderCell('P10', flex: 3, style: headerStyle),

          if (leagueId != '5') ... [
            _buildSortableHeaderCell(
              'PP%',
              'power_play_pct',
              flex: 2,
              style: headerStyle,
              groupName: groupName,
            ),
            _buildSortableHeaderCell(
              'PK%',
              'penalty_kill_pct',
              flex: 2,
              style: headerStyle,
              groupName: groupName,
            ),
          ],

          _buildSortableHeaderCell(
            'PIM',
            'pims',
            flex: 2,
            style: headerStyle,
            groupName: groupName,
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeaderUSPHL(String groupName) {
    final headerStyle = TextStyle(
      color: secondaryWhite,
      fontWeight: FontWeight.bold,
      fontSize: 12,
      fontFamily: fontFamily,
    );

    return Container(
      color: primaryBlue,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          _buildHeaderCell('#',  flex: 1, style: headerStyle),
          _buildHeaderCell('',   flex: 2, style: headerStyle),
          _buildSortableHeaderCell(
            'Team Name','team_name',
            flex: 5, style: headerStyle, groupName: groupName,
          ),
          ..._usphlColsEffective.map((c) {
            if (c.sortable) {
              return _buildSortableHeaderCell(
                c.label, c.key, flex: 2, style: headerStyle, groupName: groupName,
              );
            } else {
              return _buildHeaderCell(c.label, flex: (c.key == 'streak' || c.key == 'past_10') ? 3 : 2, style: headerStyle);
            }
          }),
        ],
      ),
    );
  }

  Widget _buildTeamRowUSPHL(Map<String, dynamic> team, int index) {
    final rowColor = index % 2 == 0 ? secondaryWhite : tertiaryGrey.withOpacity(0.05);
    final position = index + 1;
    final teamId   = team["id"]?.toString() ?? "";
    final logoUrl  = team["smlogo"]?.toString() ?? "";
    final teamName = team["team_name"]?.toString() ?? "";

    return Container(
      color: rowColor,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: Center(
              child: Text(position.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: (logoUrl.isNotEmpty)
                ? Image.network(logoUrl, width: 40, height: 40, errorBuilder: (ctx, obj, st) => const Icon(Icons.image))
                : const Icon(Icons.image),
            ),
          ),
          Expanded(
            flex: 5,
            child: TextButton(
              style: ButtonStyle(
                alignment: Alignment.centerLeft,
                padding: WidgetStateProperty.all(EdgeInsets.zero),
                minimumSize: WidgetStateProperty.all(Size.zero),
              ),
              onPressed: () {
                final cfg = js.context['widgetConfig'];
                final targetPage = cfg['teamPage'] as String;
                final uri = Uri(
                  path: targetPage,
                  queryParameters: {
                    "team": teamId,
                    if(_selectedSeason != null && _selectedSeason != 'all') "season": _selectedSeason,
                    if(_levelId != null && _levelId!.isNotEmpty) "level_id": _levelId,
                  }
                ).toString();
                html.window.location.assign(uri);
              },
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  teamName,
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    color: textColor, fontWeight: FontWeight.bold,
                    fontSize: 14, fontFamily: fontFamily,
                  ),
                ),
              ),
            ),
          ),
          ..._usphlColsEffective.map((c) {
            final raw = team[c.key] ?? (c.numeric ? 0 : '');
            final value = _fmtUSPHL(c.key, raw);
            final flex = (c.key == 'streak' || c.key == 'past_10') ? 3 : 2;
            return Expanded(
              flex: flex,
              child: Center(
                child: Text(
                  value,
                  style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildHeaderCell(String label, {required int flex, required TextStyle style}) {
    return Expanded(
      flex: flex,
      child: Center(
        child: Text(label, style: style),
      ),
    );
  }

  Widget _buildSortableHeaderCell(String label, String columnKey,
    {required int flex,
    required TextStyle style,
    required String groupName}) {

    final sortState = _sortStates[groupName];
    final isActive = (sortState != null && sortState.column == columnKey);
    final icon = isActive ? (sortState.ascending ? Icons.arrow_drop_up : Icons.arrow_drop_down) : null;

    return Expanded(
      flex: flex,
      child: InkWell(
        onTap: () => _onSortForGroup(groupName, columnKey),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Center(child: Text(label, style: style)),
            if (icon != null) ...[
              const SizedBox(width: 2),
              Icon(
                icon,
                color: secondaryWhite,
                size: 18,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTeamRow(Map<String, dynamic> team, int index) {
    final rowColor = index % 2 == 0
      ? secondaryWhite
      : tertiaryGrey.withOpacity(0.05);
    final position = index + 1;
    final teamId = team["id"]?.toString() ?? ""; 
    final logoUrl = team["smlogo"]?.toString() ?? "";
    final teamName = team["team_name"]?.toString() ?? "";
    final gp = team["games_played"] ?? 0;
    final w = team["total_wins"] ?? 0;
    final l = team["losses"] ?? 0;
    final ties = team["ties"] ?? 0; // new
    final otw = team["otwins"] ?? 0; // new
    final otl = team["otlosses"] ?? 0;
    final pts = team["pts"] ?? 0;
    final pct = double.tryParse(team["win_pct"]?.toString() ?? "0") ?? 0;
    final pts_pct = double.tryParse(team["pts_pct"]?.toString() ?? "0") ?? 0;
    final gf = team["goals_for"] ?? 0;
    final ga = team["goals_against"] ?? 0;
    final streak = team["streak"]?.toString() ?? "";
    final past10 = team["past_10"]?.toString() ?? "";
    final pp = team["power_play_pct"] ?? 0;
    final pk = team["penalty_kill_pct"] ?? 0;
    final pim = team["pims"] ?? 0;

    return Container(
      color: rowColor,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            flex: 1,
            child: Center(
              child: Text(
                position.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: (logoUrl.isNotEmpty)
                ? Image.network(
                  logoUrl,
                  width: 40,
                  height: 40,
                  errorBuilder: (ctx, obj, st) => const Icon(Icons.image),
                )
                : const Icon(Icons.image),
            ),
          ),
          Expanded(
            flex: 5,
            child: TextButton(
              style: ButtonStyle(
              alignment: Alignment.centerLeft,
              padding: WidgetStateProperty.all(EdgeInsets.zero),
              minimumSize: WidgetStateProperty.all(Size.zero),
              ),
              onPressed: () {
              final cfg = js.context['widgetConfig'];
              final targetPage = cfg['teamPage'] as String;
              final uri = Uri(
                path: targetPage,
                queryParameters: {
                "team": teamId,
                if(_selectedSeason != null && _selectedSeason != 'all')
                  "season": _selectedSeason,
                }
              ).toString();
              html.window.location.assign(uri);
              },
              child: Align(
              alignment: Alignment.centerLeft,
                child: Text(
                  teamName,
                  maxLines: 2,
                  softWrap: true,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    fontFamily: fontFamily,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                gp.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                w.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                l.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                ties.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                otw.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                otl.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),

          if (_showKrach) ...[
            Expanded(
              flex: 3,
              child: Center(child: Text(_fmt0(team['krach']), style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily))),
            ),
            Expanded(
              flex: 3,
              child: Center(child: Text(_fmt0(team['strength_of_schedule']), style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily))),
            ),
          ],

          if(leagueId != '5')
            Expanded(
              flex: 2,
              child: Center(
                child: Text(
                  pts.toString(),
                  style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
                ),
              ),
            ),

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                pct.toStringAsFixed(3),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                pts_pct.toStringAsFixed(3),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                gf.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                ga.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Center(
              child: Text(
                streak,
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Center(
              child: Text(
                past10,
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),

          if (leagueId != '5') ... [
            Expanded(
              flex: 2,
              child: Center(
                child: Text(
                  "${pp.toStringAsFixed(2)}",
                  style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Center(
                child: Text(
                  "${pk.toStringAsFixed(2)}",
                  style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
                ),
              ),
            ),
          ],

          Expanded(
            flex: 2,
            child: Center(
              child: Text(
                pim.toString(),
                style: TextStyle(color: textColor, fontSize: 12, fontFamily: fontFamily,),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
