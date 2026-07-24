import 'dart:io';

void main() async {
  const path = r'C:\dev\foobar-app\tmp_explorer_test\NoSpaceFolder\song.mp3';
  final result = await Process.run('explorer.exe', ['/select,$path']);
  print('exitCode=${result.exitCode}');
}
