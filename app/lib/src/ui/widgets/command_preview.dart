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
              _LabeledCommandButton(
                label: copySemanticsLabel,
                text: 'Copy',
                onPressed: copyEnabled ? () {} : null,
              ),
              if (showRunActions) ...[
                _LabeledCommandButton(
                  label: 'Run terminal launch command',
                  text: 'Run',
                  onPressed: copyEnabled ? () {} : null,
                ),
                _LabeledCommandButton(
                  label: 'Edit terminal launch command before running',
                  text: 'Edit and run',
                  onPressed: copyEnabled ? () {} : null,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _LabeledCommandButton extends StatelessWidget {
  const _LabeledCommandButton({
    required this.label,
    required this.text,
    required this.onPressed,
  });

  final String label;
  final String text;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: OutlinedButton(onPressed: onPressed, child: Text(text)),
      ),
    );
  }
}
