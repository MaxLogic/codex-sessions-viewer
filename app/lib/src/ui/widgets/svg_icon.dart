import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class AppSvgIcon extends StatelessWidget {
  const AppSvgIcon(this.assetName, {super.key, this.size = 16, this.color});

  final String assetName;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolvedColor =
        color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color;
    return SvgPicture.asset(
      assetName,
      width: size,
      height: size,
      excludeFromSemantics: true,
      colorFilter: resolvedColor == null
          ? null
          : ColorFilter.mode(resolvedColor, BlendMode.srcIn),
    );
  }
}

class AppIcons {
  const AppIcons._();

  static const archive = 'assets/icons/action_archive.svg';
  static const cancel = 'assets/icons/action_cancel.svg';
  static const check = 'assets/icons/action_check.svg';
  static const copy = 'assets/icons/action_copy.svg';
  static const deleteSweep = 'assets/icons/action_delete_sweep.svg';
  static const edit = 'assets/icons/action_edit.svg';
  static const export = 'assets/icons/action_export.svg';
  static const file = 'assets/icons/action_file.svg';
  static const filter = 'assets/icons/action_filter.svg';
  static const filterClear = 'assets/icons/action_filter_clear.svg';
  static const folderOpen = 'assets/icons/action_folder_open.svg';
  static const fork = 'assets/icons/action_fork.svg';
  static const pin = 'assets/icons/action_pin.svg';
  static const play = 'assets/icons/action_play.svg';
  static const refresh = 'assets/icons/action_refresh.svg';
  static const reparse = 'assets/icons/action_reparse.svg';
  static const save = 'assets/icons/action_save.svg';
  static const settings = 'assets/icons/action_settings.svg';
  static const terminal = 'assets/icons/action_terminal.svg';
  static const tag = 'assets/icons/action_tag.svg';
  static const messageUser = 'assets/icons/message_user.svg';
  static const messageAssistant = 'assets/icons/message_assistant.svg';
  static const messageTool = 'assets/icons/message_tool.svg';
  static const expand = 'assets/icons/nav_expand.svg';
  static const collapse = 'assets/icons/nav_collapse.svg';
}
