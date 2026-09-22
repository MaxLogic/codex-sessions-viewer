/// A choice from the "Move to project" dialog.
sealed class SessionProjectChange {
  const SessionProjectChange();
}

/// Moves only this session; it keeps the project until it is reset.
class MoveSessionToProject extends SessionProjectChange {
  const MoveSessionToProject(this.projectName);

  final String projectName;
}

/// Moves every session from [folder] and its subfolders, for example a
/// worktree merged back into its main project.
class MoveFolderToProject extends SessionProjectChange {
  const MoveFolderToProject({required this.folder, required this.projectName});

  final String folder;
  final String projectName;
}

/// Drops a project set by hand, so folder rules and detection apply again.
class ResetSessionProject extends SessionProjectChange {
  const ResetSessionProject();
}

/// Deletes the folder rule for [folder].
class RemoveFolderRule extends SessionProjectChange {
  const RemoveFolderRule(this.folder);

  final String folder;
}
