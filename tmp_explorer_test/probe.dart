import 'dart:io';

// Exact reproduction of app/lib/ui/track_list.dart's _launchInExplorer:
//   Process.run('explorer.exe', ['/select,${_windowsPathOf(track)}']);
void main() async {
  const path = r'C:\dev\foobar-app\tmp_explorer_test\loose tracks - old\test song.mp3';
  final result = await Process.run('explorer.exe', ['/select,$path']);
  print('exitCode=${result.exitCode}');
  print('stdout=${result.stdout}');
  print('stderr=${result.stderr}');
}
