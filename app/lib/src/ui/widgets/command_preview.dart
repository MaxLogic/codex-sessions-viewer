import 'package:flutter/material.dart';

import '../../commands/resume_command_generator.dart';

class CommandPreview extends StatelessWidget {
  const CommandPreview({super.key, required this.commandSet});

  final ResumeCommandSet commandSet;

  @override
  Widget build(BuildContext context) {
    final disabledReason = commandSet.disabledReason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Command preview', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (disabledReason != null)
          Text(disabledReason)
        else ...[
          _CommandBlock(
            label: 'Plain resume command:',
            command: commandSet.plainResumeCommand,
            copyEnabled: commandSet.plainResumeCommand != null,
            copySemanticsLabel: 'Copy plain resume command',
          ),
          _CommandBlock(
            label: 'Platform resume command:',
            command: commandSet.platformResumeCommand,
            copyEnabled: commandSet.platformResumeCommand != null,
            copySemanticsLabel: 'Copy platform resume command',
          ),
          _CommandBlock(
            label: 'Terminal launch command:',
            command:
                commandSet.terminalLaunchCommand ??
                commandSet.terminalDisabledReason,
            copyEnabled: commandSet.terminalLaunchCommand != null,
            showRunActions: true,
            copySemanticsLabel: 'Copy terminal launch command',
          ),
        ],
      ],
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({
    required this.label,
    required this.command,
    required this.copyEnabled,
    required this.copySemanticsLabel,
    this.showRunActions = false,
  });

  final String label;
  final String? command;
  final bool copyEnabled;
  final String copySemanticsLabel;
  final bool showRunActions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          const SizedBox(height: 4),
          SelectableText(command ?? 'Unavailable'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Semantics(
                label: copySemanticsLabel,
                button: true,
                child: OutlinedButton(
                  onPressed: copyEnabled ? () {} : null,
                  child: const Text('Copy'),
                ),
              ),
              if (showRunActions) ...[
                OutlinedButton(
                  onPressed: copyEnabled ? () {} : null,
                  child: const Text('Run'),
                ),
                OutlinedButton(
                  onPressed: copyEnabled ? () {} : null,
                  child: const Text('Edit and run'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
