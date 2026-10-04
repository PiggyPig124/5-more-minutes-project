import 'dart:async';

import 'package:flutter/material.dart';

import 'api_client.dart';
import 'app_controller.dart';

/// Shared content is reauthorized on entry, resume and while in the foreground.
class TaskAccessRefresh extends StatefulWidget {
  const TaskAccessRefresh(
      {required this.controller, required this.child, this.taskId, super.key});

  final AppController controller;
  final Widget child;
  final String? taskId;

  @override
  State<TaskAccessRefresh> createState() => _TaskAccessRefreshState();
}

class _TaskAccessRefreshState extends State<TaskAccessRefresh>
    with WidgetsBindingObserver {
  Timer? _timer;
  int _epoch = 0;
  int? _refreshingEpoch;
  bool _foreground = true;
  bool _entryStarted = false;
  bool get _enabled =>
      (widget.controller.isCaregiver || widget.taskId != null) &&
      widget.controller.api is TaskSharingApi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _start();
        setState(() => _entryStarted = true);
      }
    });
  }

  void _start() {
    _timer?.cancel();
    if (!_enabled || !_foreground) return;
    unawaited(_refresh());
    _timer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (!mounted ||
        !_enabled ||
        !_foreground ||
        _refreshingEpoch == _epoch ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final epoch = _epoch;
    _refreshingEpoch = epoch;
    try {
      if (widget.taskId == null) {
        await widget.controller.refreshTasks();
      } else {
        await widget.controller.refreshTaskDetail(widget.taskId!);
      }
    } finally {
      if (_refreshingEpoch == epoch) _refreshingEpoch = null;
    }
  }

  @override
  void didUpdateWidget(TaskAccessRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _start();
    } else {
      _epoch++;
      _refreshingEpoch = null;
      _timer?.cancel();
      if (_enabled) {
        if (widget.taskId == null) {
          unawaited(widget.controller.invalidateSharedTaskAccess());
        } else {
          unawaited(widget.controller.invalidateTaskDetail(widget.taskId!));
        }
      }
    }
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _enabled && !_entryStarted
      ? const Center(child: CircularProgressIndicator())
      : widget.child;
}
