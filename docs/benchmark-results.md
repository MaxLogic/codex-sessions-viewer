# Local Benchmark Results

> Historical report. The Dart session scanner, parser, and the command that
> generated this file were removed when the Rust collector became the only
> session parser; the numbers describe that retired implementation.

Generated UTC: 2026-06-14T23:59:40.268312Z

## Machine and Toolchain

- Operating system: windows
- Dart version: 3.12.1 (stable) (Tue May 26 01:02:21 2026 -0700) on "windows_x64"
- Dataset: 6 supported fixture files

## Command

`dart run bin/benchmark_local.dart --fixtures <fixtures> --out <out>`

The report is content-safe: it records aggregate counts and durations only, with no raw session paths, prompts, messages, tool output, or token values.
Coverage: scanner, parser, cache, search, build, package.

## Scanner throughput

- Elapsed: 50 ms
- Files found: 6
- Files parsed: 4
- Files failed: 2
- Sessions available: 4

## Parser throughput

- Elapsed: 4 ms
- Files parsed: 6
- Successful parses: 4
- Failed parses: 2

## Cache invalidation skip time

- Elapsed: 6 ms
- Files found: 6
- Files skipped: 4
- Files parsed: 0

## SQLite upsert/search

- Elapsed: 43 ms
- Documents indexed: 4
- Search hits for benchmark query: 3

## Release build/package timing

- Build script: 34724 ms
- Package script: 35986 ms
