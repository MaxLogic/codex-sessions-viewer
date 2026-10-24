$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
# Exclusive opens catch handles even when they allow deletion. Check the whole
# fixture before removing any evidence; do not retry or ignore sharing errors.
foreach ($file in Get-ChildItem -LiteralPath $env:CSV_TEST_FIXTURE_ROOT -Recurse -File) {
  $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
  $stream.Dispose()
}
