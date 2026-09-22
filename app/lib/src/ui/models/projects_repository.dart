import '../../database/project_tag_state.dart';

/// What the Projects screen reads and changes. Every edit returns the folder
/// rules and manual session projects from before it, so it can be undone
/// with [restore].
abstract interface class ProjectsRepository {
  Future<List<ProjectSummary>> loadProjects();

  Future<ProjectDetail> loadProjectDetail(int projectId);

  Future<ProjectRulesSnapshot> addFolderRule({
    required String folder,
    required String projectName,
  });

  Future<ProjectRulesSnapshot> changeFolderRule({
    required String oldFolder,
    required String newFolder,
    required String projectName,
  });

  /// Points the rule for [folder] at another project.
  Future<ProjectRulesSnapshot> moveFolderRule({
    required String folder,
    required String projectName,
  });

  Future<ProjectRulesSnapshot> removeFolderRule(String folder);

  Future<ProjectRulesSnapshot> mergeProject({
    required int sourceProjectId,
    required String targetName,
  });

  Future<ProjectRulesSnapshot> resetManualSessions(int projectId);

  Future<void> restore(ProjectRulesSnapshot snapshot);
}
