import 'resume_command_generator.dart';

/// Splits a Windows command line into a program and arguments following the
/// Microsoft C runtime rules, so an edited terminal command can be started
/// without a shell.
///
/// Returns null for an empty command line.
TerminalLaunchSpec? parseWindowsCommandLine(String commandLine) {
  final args = splitWindowsCommandLine(commandLine);
  if (args.isEmpty) {
    return null;
  }
  return TerminalLaunchSpec(executable: args.first, arguments: args.sublist(1));
}

List<String> splitWindowsCommandLine(String commandLine) {
  final args = <String>[];
  final current = StringBuffer();
  var inQuotes = false;
  var hasToken = false;
  var i = 0;
  while (i < commandLine.length) {
    final char = commandLine[i];
    if (char == r'\') {
      var backslashes = 0;
      while (i < commandLine.length && commandLine[i] == r'\') {
        backslashes++;
        i++;
      }
      if (i < commandLine.length && commandLine[i] == '"') {
        // 2n backslashes + quote: n backslashes, quote is a delimiter.
        // 2n+1 backslashes + quote: n backslashes and a literal quote.
        current.write(r'\' * (backslashes ~/ 2));
        if (backslashes.isOdd) {
          current.write('"');
          i++;
        }
      } else {
        current.write(r'\' * backslashes);
      }
      hasToken = true;
      continue;
    }
    if (char == '"') {
      if (inQuotes && i + 1 < commandLine.length && commandLine[i + 1] == '"') {
        // A doubled quote inside quotes is a literal quote.
        current.write('"');
        i += 2;
        hasToken = true;
        continue;
      }
      inQuotes = !inQuotes;
      hasToken = true;
      i++;
      continue;
    }
    if (!inQuotes && (char == ' ' || char == '\t')) {
      if (hasToken) {
        args.add(current.toString());
        current.clear();
        hasToken = false;
      }
      i++;
      continue;
    }
    current.write(char);
    hasToken = true;
    i++;
  }
  if (hasToken) {
    args.add(current.toString());
  }
  return args;
}
