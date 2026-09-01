# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 - Unreleased

Initial release.

### Added

- `Mutare.Oban.WorkerReturn` (`:oban_worker_return`) — swaps `perform/1`
  return values for other *valid* Oban returns (`:ok`/`{:ok, v}` →
  `{:error, :mutare}`; `{:error, reason}` → `:ok` / `{:cancel, reason}`;
  `{:cancel, reason}` → `{:error, reason}` / `:ok`; `{:snooze, s}` → `:ok`;
  legacy `{:discard, reason}` → `:ok` / `{:cancel, reason}` and bare
  `:discard` → `:ok`). Behaviour-gated: fires only inside `Oban.Worker` /
  `Oban.Pro.Worker` modules, and reaches branch tails via
  `return_replacements`. Declares `required_modules/0`, so a run where Oban
  is not loadable aborts loudly instead of silently producing no mutants.
- `Mutare.Oban.Enqueue` (`:oban_enqueue`) — rewrites `MyWorker.new(args, opts)`
  enqueue options (direct, aliased, or piped): `max_attempts: n` → `1` (n ≠ 1),
  and drops `unique:`, `schedule_in:`, and `scheduled_at:`.
- Report notes on every mutant naming what a survivor leaves unasserted.
- Ignore-variant labels on both families, so
  `# mutare:ignore[oban_worker_return:ok]` /
  `# mutare:ignore[oban_enqueue:unique]` can suppress one kind of mutant.
- `Mutare.Oban.all/0` for splicing both families into a `:mutators` list.
