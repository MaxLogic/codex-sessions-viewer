import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/resume_command_generator.dart';
import 'svg_icon.dart';
import 'app_button.dart';

typedef TerminalCommandCallback = Future<void> Function(String command);

class CommandPreview extends StatelessWidget {
  const CommandPreview({
    super.key,
    required this.commandSet,
    this.onRunTerminalCommand,
    this.onEditTerminalCommand,
    this.showInlineActions = true,
  });

  final ResumeCommandSet commandSet;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;
  final bool showInlineActions;

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
            onRunTerminalCommand: onRunTerminalCommand,
            onEditTerminalCommand: onEditTerminalCommand,
            showInlineActions: showInlineActions,
          ),
          _CommandBlock(
            label: 'Platform resume command:',
            command: commandSet.platformResumeCommand,
            copyEnabled: commandSet.platformResumeCommand != null,
            copySemanticsLabel: 'Copy platform resume command',
            onRunTerminalCommand: onRunTerminalCommand,
            onEditTerminalCommand: onEditTerminalCommand,
            showInlineActions: showInlineActions,
          ),
          _CommandBlock(
            label: 'Terminal launch command:',
            command:
                commandSet.terminalLaunchCommand ??
                commandSet.terminalDisabledReason,
            copyEnabled: commandSet.terminalLaunchCommand != null,
            showRunActions: true,
            copySemanticsLabel: 'Copy terminal launch command',
            onRunTerminalCommand: onRunTerminalCommand,
            onEditTerminalCommand: onEditTerminalCommand,
            showInlineActions: showInlineActions,
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
    required this.onRunTerminalCommand,
    required this.onEditTerminalCommand,
    this.showRunActions = false,
    this.showInlineActions = true,
  });

  final String label;
  final String? command;
  final bool copyEnabled;
  final String copySemanticsLabel;
  final bool showRunActions;
  final bool showInlineActions;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;

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
          if (showInlineActions)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _LabeledCommandButton(
                  label: copySemanticsLabel,
                  text: 'Copy',
                  iconAsset: AppIcons.copy,
                  onPressed: copyEnabled && command != null
                      ? () => _copyCommand(context, command!)
                      : null,
                ),
                if (showRunActions) ...[
                  _LabeledCommandButton(
                    label: 'Run terminal launch command',
                    text: 'Run',
                    iconAsset: AppIcons.play,
                    onPressed: copyEnabled && command != null
                        ? () => _runTerminalCommand(context, command!)
                        : null,
                  ),
                  _LabeledCommandButton(
                    label: 'Edit terminal launch command before running',
                    text: 'Edit and run',
                    iconAsset: AppIcons.edit,
                    onPressed: copyEnabled && command != null
                        ? () => _editTerminalCommand(context, command!)
                        : null,
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _copyCommand(BuildContext context, String command) async {
    await Clipboard.setData(ClipboardData(text: command));
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Command copied.')));
  }

  Future<void> _runTerminalCommand(BuildContext context, String command) async {
    final callback = onRunTerminalCommand;
    if (callback != null) {
      await callback(command);
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Terminal command run requested.')),
    );
  }

  Future<void> _editTerminalCommand(
    BuildContext context,
    String command,
  ) async {
    final controller = TextEditingController(text: command);
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit terminal command'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Command'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          AppButton.filled(
            onPressed: () => Navigator.of(context).pop(controller.text),
            icon: const AppSvgIcon(AppIcons.play),
            label: const Text('Run'),
          ),
        ],
      ),
    );
    if (edited == null) {
      return;
    }
    final callback = onEditTerminalCommand ?? onRunTerminalCommand;
    if (callback != null) {
      await callback(edited);
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Edited terminal command run requested.')),
    );
  }
}

class _LabeledCommandButton extends StatelessWidget {
  const _LabeledCommandButton({
    required this.label,
    required this.text,
    required this.iconAsset,
    required this.onPressed,
  });

  final String label;
  final String text;
  final String iconAsset;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: AppButton.outlined(
          onPressed: onPressed,
          icon: AppSvgIcon(iconAsset),
          label: Text(text),
        ),
      ),
    );
  }
}
