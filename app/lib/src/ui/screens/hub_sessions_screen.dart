import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/hub_data_source.dart';
import '../../commands/remote_session_actions.dart';
import '../../config/app_settings.dart';

/// Local contents stay mounted when switching sources. Hub data is bounded to
/// the current page and selected conversation page, never copied into SQLite.
class SessionSourcePane extends StatefulWidget {
  const SessionSourcePane({
    super.key,
    required this.local,
    required this.settingsFile,
    required this.databaseFile,
    required this.settings,
  });
  final Widget local;
  final File settingsFile;
  final File databaseFile;
  final AppSettings settings;
  @override
  State<SessionSourcePane> createState() => _SessionSourcePaneState();
}

class _SessionSourcePaneState extends State<SessionSourcePane> {
  bool _hub = false;
  bool _openedHub = false;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('This machine')),
            ButtonSegment(value: true, label: Text('Hub')),
          ],
          selected: {_hub},
          onSelectionChanged: (value) => setState(() {
            _hub = value.single;
            _openedHub |= _hub;
          }),
        ),
      ),
      Expanded(
        child: IndexedStack(
          index: _hub ? 1 : 0,
          children: [
            widget.local,
            if (_openedHub)
              HubSessionsScreen(
                active: _hub,
                settings: widget.settings,
                settingsFile: widget.settingsFile,
                databaseFile: widget.databaseFile,
              )
            else
              const SizedBox.shrink(),
          ],
        ),
      ),
    ],
  );
}

class HubSessionsScreen extends StatefulWidget {
  const HubSessionsScreen({
    super.key,
    required this.settings,
    required this.settingsFile,
    required this.databaseFile,
    this.source,
    this.active = true,
    this.pollInterval = const Duration(seconds: 10),
  });
  final AppSettings settings;
  final File settingsFile;
  final File databaseFile;
  final HubDataSource? source;
  final bool active;
  final Duration pollInterval;
  @override
  State<HubSessionsScreen> createState() => _HubSessionsScreenState();
}

class _HubSessionsScreenState extends State<HubSessionsScreen> {
  HubDataSource? _source;
  late final TextEditingController _url;
  final _token = TextEditingController();
  final _search = TextEditingController();
  final _title = TextEditingController();
  final _notes = TextEditingController();
  Timer? _timer;
  List<String> _machines = [];
  String? _machine;
  String? _cursor;
  String? _next;
  String _query = '';
  final List<String?> _previous = [];
  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>>? _usage;
  Map<String, dynamic>? _selected;
  Map<String, dynamic>? _detail;
  RemoteActionEligibility? _actions;
  int? _nextMessage;
  int _annotationRevision = 0;
  bool _busy = false;
  bool _annotationLoaded = false;
  bool _annotationDirty = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.settings.hub.url);
    _token.text = Platform.environment['CODEX_SESSIONS_HUB_OWNER_TOKEN'] ?? '';
    _machine = widget.settings.hub.machine.isEmpty
        ? null
        : widget.settings.hub.machine;
    if (widget.source != null) {
      _source = widget.source;
      unawaited(_connect());
    }
    _timer = Timer.periodic(widget.pollInterval, (_) {
      if (widget.active && _source != null && !_busy && !_annotationDirty) {
        unawaited(_reload());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.source == null) _source?.close();
    for (final controller in [_url, _token, _search, _title, _notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.source == null) {
        _source?.close();
        _source = null;
        _source = HubDataSource(url: _url.text.trim(), ownerToken: _token.text);
      }
      final machines = await _source!.machines();
      if (!mounted) return;
      _machines = machines;
      if (!machines.contains(_machine)) _machine = machines.firstOrNull;
      _cursor = null;
      _previous.clear();
      await _remember();
    } catch (error) {
      if (mounted) _error = 'Hub: $error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (_error == null) await _reload();
  }

  Future<void> _remember() async {
    if (widget.source != null) return;
    await SettingsRepository(widget.settingsFile).update(
      (current) => current.copyWith(
        hub: HubSettings(url: _url.text.trim(), machine: _machine ?? ''),
      ),
    );
  }

  List<Map<String, dynamic>> _maps(Object? value) => (value as List? ?? [])
      .map((item) => (item as Map).cast<String, dynamic>())
      .toList();
  String _reference(Map<String, dynamic> row) =>
      (row['session_reference'] ?? row['reference']) as String;

  Future<void> _reload() async {
    if (_busy || _source == null || _machine == null) return;
    final generation = ++_generation;
    setState(() => _busy = true);
    try {
      final page = await _source!.sessions(
        _machine!,
        search: _query,
        cursor: _cursor,
      );
      if (!mounted || generation != _generation) return;
      final selectedRef = _selected == null ? null : _reference(_selected!);
      setState(() {
        _rows = _maps(page['results']);
        _next = page['next_cursor'] as String?;
        _error = null;
        if (selectedRef != null) {
          final matches = _rows.where((row) => _reference(row) == selectedRef);
          // Keep selected identity even when a new ingest moves it off this page.
          if (matches.isNotEmpty) _selected = matches.first;
        }
      });
      if (_selected != null && !_annotationDirty) {
        final reference = _reference(_selected!);
        final current = _rows.where((row) => _reference(row) == reference);
        if (current.isNotEmpty &&
            current.first['last_parsed_utc'] != _detail?['last_parsed_utc']) {
          final detail = await _source!.detail(_machine!, reference);
          final messages = await _source!.messages(_machine!, reference);
          if (mounted && generation == _generation) {
            setState(() {
              _detail = (detail['session'] as Map).cast<String, dynamic>();
              _messages = _maps(messages['results']);
              _nextMessage = messages['next_after_index'] as int?;
            });
          }
        }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = 'Hub: $error Last successful rows remain visible.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One hub request sequence runs at a time: a tap delivered after a poll
  /// started (before the disabled row was rebuilt) is ignored rather than
  /// overlapping it, and the poll cannot clear this request's busy state.
  Future<void> _select(Map<String, dynamic> row) async {
    if (_busy || _source == null || _machine == null) return;
    if (!await _discardEdits() || !mounted || _busy) return;
    final reference = _reference(row);
    final generation = ++_generation;
    setState(() {
      _selected = row;
      _detail = null;
      _messages = [];
      _actions = null;
      _annotationLoaded = false;
      _annotationDirty = false;
      _busy = true;
      _error = null;
    });
    try {
      final detail = await _source!.detail(_machine!, reference);
      final messages = await _source!.messages(_machine!, reference);
      final annotation = await _source!.annotations(_machine!, reference);
      final summary = (detail['session'] as Map).cast<String, dynamic>();
      final actions = await RemoteSessionActions(
        databaseFile: widget.databaseFile,
        settings: widget.settings,
      ).inspect(summary);
      if (!mounted || generation != _generation) return;
      setState(() {
        _detail = summary;
        _messages = _maps(messages['results']);
        _nextMessage = messages['next_after_index'] as int?;
        _actions = actions;
        _annotationRevision = annotation['revision'] as int;
        _title.text = annotation['title'] as String? ?? '';
        _notes.text = annotation['notes'] as String? ?? '';
        _annotationLoaded = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Hub details: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _discardEdits() async {
    if (!_annotationDirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved hub annotations?'),
            content: const Text(
              'Your title and notes have not been saved to the hub.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard changes'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _submitSearch() {
    if (_busy) return;
    _query = _search.text.trim();
    _cursor = null;
    _previous.clear();
    unawaited(_reload());
  }

  Future<void> _operation(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = 'Hub: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mapFolder() async {
    final controller = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Map remote directory to a local folder'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Existing local folder'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Use folder'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (path == null || _detail == null) return;
    await _operation(() async {
      final actions = await RemoteSessionActions(
        databaseFile: widget.databaseFile,
        settings: widget.settings,
      ).inspect(_detail!, explicitLocalMapping: path);
      if (mounted) setState(() => _actions = actions);
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Hub history', style: TextStyle(fontSize: 20)),
        if (_machines.isEmpty) ...[
          TextField(
            controller: _url,
            decoration: const InputDecoration(labelText: 'Hub URL'),
          ),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Owner token (kept in memory)',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy ? null : _connect,
              child: const Text('Connect to hub'),
            ),
          ),
        ] else
          Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  key: ValueKey(_machine),
                  initialValue: _machine,
                  decoration: const InputDecoration(labelText: 'Hub machine'),
                  items: _machines
                      .map(
                        (machine) => DropdownMenuItem(
                          value: machine,
                          child: Text(machine),
                        ),
                      )
                      .toList(),
                  hint: const Text('Hub machine'),
                  onChanged: _busy
                      ? null
                      : (machine) async {
                          if (!await _discardEdits() || !mounted) return;
                          setState(() {
                            _annotationDirty = false;
                            _machine = machine;
                            _selected = null;
                            _detail = null;
                            _rows = [];
                            _usage = null;
                            _cursor = null;
                            _previous.clear();
                          });
                          await _remember();
                          await _reload();
                        },
                ),
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    labelText: 'Search hub messages',
                  ),
                  onSubmitted: (_) => _submitSearch(),
                ),
              ),
              TextButton(
                onPressed: _busy ? null : _submitSearch,
                child: const Text('Search / refresh hub'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _operation(() async {
                        final usage = await _source!.usage(_machine!);
                        if (mounted) {
                          setState(() => _usage = _maps(usage['days']));
                        }
                      }),
                child: const Text('Hub usage'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        if (!await _discardEdits() || !mounted) return;
                        _generation++;
                        _source?.close();
                        setState(() {
                          _source = null;
                          _machines = [];
                          _rows = [];
                          _selected = null;
                          _detail = null;
                          _usage = null;
                          _annotationDirty = false;
                        });
                      },
                child: const Text('Disconnect'),
              ),
            ],
          ),
        if (_busy)
          Semantics(liveRegion: true, child: const Text('Loading hub data…')),
        if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
        if (_usage != null)
          SizedBox(
            height: 100,
            child: ListView.builder(
              itemCount: _usage!.length,
              itemBuilder: (context, index) {
                final day = _usage![index];
                return Text('${day['day_utc']}: ${day['total_tokens']} tokens');
              },
            ),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    if (_machines.isNotEmpty &&
                        _rows.isEmpty &&
                        !_busy &&
                        _error == null)
                      const Text('No sessions in this hub query.'),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _rows.length,
                        itemBuilder: (context, index) {
                          final row = _rows[index];
                          final reference = _reference(row);
                          return ListTile(
                            key: ValueKey(
                              'hub-$reference-${row['message_index'] ?? ''}',
                            ),
                            selected:
                                _selected != null &&
                                _reference(_selected!) == reference,
                            title: Text(
                              '${row['title'] ?? row['session_key'] ?? reference}',
                            ),
                            subtitle: Text(
                              '${row['harness']} · ${row['environment']} · ${row['project'] ?? ''}',
                            ),
                            onTap: _busy ? null : () => _select(row),
                          );
                        },
                      ),
                    ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: _busy || _previous.isEmpty
                              ? null
                              : () {
                                  _cursor = _previous.removeLast();
                                  unawaited(_reload());
                                },
                          child: const Text('Previous page'),
                        ),
                        TextButton(
                          onPressed: _busy || _next == null
                              ? null
                              : () {
                                  _previous.add(_cursor);
                                  _cursor = _next;
                                  unawaited(_reload());
                                },
                          child: const Text('Next page'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const VerticalDivider(),
              Expanded(
                child: _detail == null
                    ? const Center(child: Text('Select a hub session.'))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Source title: ${_detail!['title'] ?? ''}'),
                          Text(
                            'Machine: $_machine · ${_detail!['harness']} · ${_detail!['environment']}',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: _busy || _actions?.resume == null
                                    ? null
                                    : () => _operation(() async {
                                        final checked =
                                            await RemoteSessionActions(
                                              databaseFile: widget.databaseFile,
                                              settings: widget.settings,
                                            ).inspect(_detail!);
                                        final spec = checked.resume;
                                        if (spec == null) {
                                          throw HubFailure(
                                            checked.resumeReason ??
                                                'Resume unavailable.',
                                          );
                                        }
                                        await Process.start(
                                          spec.executable,
                                          spec.arguments,
                                        );
                                      }),
                                child: const Text('Resume locally'),
                              ),
                              TextButton(
                                onPressed: _busy || _actions?.directory == null
                                    ? null
                                    : () => _operation(() async {
                                        final path = _actions!.directory!;
                                        if (!await Directory(path).exists()) {
                                          throw const HubFailure(
                                            'The mapped directory no longer exists.',
                                          );
                                        }
                                        await Process.start('explorer.exe', [
                                          path,
                                        ]);
                                      }),
                                child: const Text('Open local directory'),
                              ),
                              TextButton(
                                onPressed: _busy ? null : _mapFolder,
                                child: const Text('Map local folder'),
                              ),
                            ],
                          ),
                          if (_actions?.resumeReason != null)
                            Text(_actions!.resumeReason!),
                          if (_actions?.directoryReason != null)
                            Text(_actions!.directoryReason!),
                          TextField(
                            controller: _title,
                            enabled: _annotationLoaded,
                            decoration: const InputDecoration(
                              labelText: 'Hub title annotation',
                            ),
                            onChanged: (_) => _annotationDirty = true,
                          ),
                          TextField(
                            controller: _notes,
                            enabled: _annotationLoaded,
                            decoration: const InputDecoration(
                              labelText: 'Hub notes (owned by hub)',
                            ),
                            onChanged: (_) => _annotationDirty = true,
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _busy || !_annotationLoaded
                                  ? null
                                  : () => _operation(() async {
                                      final annotation = await _source!
                                          .editAnnotations(
                                            _machine!,
                                            _reference(_selected!),
                                            revision: _annotationRevision,
                                            title: _title.text,
                                            notes: _notes.text,
                                          );
                                      _annotationRevision =
                                          annotation['revision'] as int;
                                      _annotationDirty = false;
                                    }),
                              child: const Text('Save hub annotations'),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _messages.length,
                              itemBuilder: (context, index) {
                                final message = _messages[index];
                                return ListTile(
                                  title: Text('${message['author_type']}'),
                                  subtitle: SelectableText(
                                    '${message['excerpt'] ?? ''}',
                                  ),
                                  trailing:
                                      message['excerpt_truncated'] == true ||
                                          (message['text_offset'] as int? ??
                                                  0) >
                                              0
                                      ? TextButton(
                                          onPressed: _busy
                                              ? null
                                              : () => _operation(() async {
                                                  final offset =
                                                      message['excerpt_truncated'] ==
                                                          true
                                                      ? message['next_text_offset']
                                                                as int? ??
                                                            (message['excerpt']
                                                                    as String)
                                                                .runes
                                                                .length
                                                      : 0;
                                                  final chunk = await _source!
                                                      .message(
                                                        _machine!,
                                                        _reference(_selected!),
                                                        message['message_index']
                                                            as int,
                                                        offset,
                                                      );
                                                  if (mounted) {
                                                    setState(
                                                      () => _messages[index] =
                                                          (chunk['result']
                                                                  as Map)
                                                              .cast<
                                                                String,
                                                                dynamic
                                                              >(),
                                                    );
                                                  }
                                                }),
                                          child: Text(
                                            message['excerpt_truncated'] == true
                                                ? 'Continue message'
                                                : 'Message beginning',
                                          ),
                                        )
                                      : null,
                                );
                              },
                            ),
                          ),
                          TextButton(
                            onPressed: _busy || _nextMessage == null
                                ? null
                                : () => _operation(() async {
                                    final page = await _source!.messages(
                                      _machine!,
                                      _reference(_selected!),
                                      after: _nextMessage,
                                    );
                                    if (mounted) {
                                      setState(() {
                                        _messages = _maps(page['results']);
                                        _nextMessage =
                                            page['next_after_index'] as int?;
                                      });
                                    }
                                  }),
                            child: const Text('Next messages'),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
