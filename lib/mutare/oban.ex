defmodule Mutare.Oban do
  @moduledoc """
  Mutation-testing mutators for [Oban](https://hexdocs.pm/oban) — a plugin for
  [Mutare](https://hexdocs.pm/mutare).

  Oban worker code concentrates its *interesting* behaviour at two positions ordinary
  mutators only graze:

    * the **return value of `perform/1`** — the contract that decides whether a job
      completes, retries, cancels, or snoozes; and
    * the **enqueue options** (`max_attempts:`, `unique:`, `schedule_in:`, …) — the
      retry / dedup / scheduling policy.

  This plugin mints *well-formed-but-wrong* Oban programs at exactly those spots, so a
  **surviving** mutant points at a precise gap in the suite — *no test asserts that this
  failed job retries / that this job dedupes / that this snooze reschedules* — rather than
  merely crashing.

  It is two independent `Mutare.Mutator`s, listed alongside the built-ins:

      # .mutare.exs
      [mutators: [:builtins, Mutare.Oban.WorkerReturn, Mutare.Oban.Enqueue]]

  or, equivalently, splicing the convenience list:

      [mutators: [:builtins] ++ Mutare.Oban.all()]

  (`:builtins` keeps Mutare's default families and *adds* these; omit it to run the Oban
  mutators alone.) Each records under its own report family — `:oban_worker_return` and
  `:oban_enqueue` — so survivors are attributed precisely and either can be enabled alone.

  Both families declare **ignore-variant labels**, so a `# mutare:ignore[family:label]`
  directive can suppress one kind of mutant without silencing the family — e.g.
  `# mutare:ignore[oban_worker_return:ok]` keeps the cancel swap but drops the
  failure-swallowing `:ok` swap on that line. `Mutare.Oban.WorkerReturn` labels each swap by
  the return it becomes (`ok` / `error` / `cancel`); `Mutare.Oban.Enqueue` labels each
  mutation by the option it attacks (`max_attempts` / `unique` / `schedule_in` /
  `scheduled_at`) and attaches a report note saying what a survivor leaves unasserted.

  ## What fits cleanly, and what doesn't

  `Mutare.Oban.WorkerReturn` is behaviour-gated: it fires only inside modules that implement
  `Oban.Worker` (or `Oban.Pro.Worker`). Mutare detects that through its `use`-expansion —
  `use Oban.Worker` injects `@behaviour Oban.Worker` — so **Oban must be loadable in the
  Mutare process** (it is, since `mix mutare` runs with the target's deps on the path).
  `Mutare.Oban.WorkerReturn` declares that requirement via
  `c:Mutare.Mutator.required_modules/0`, so a run where Oban is absent aborts loudly at
  startup instead of silently producing no worker-return mutants.

  Two things are deliberately *out of scope* because they are not runtime positions Mutare can
  splice a selector into:

    * **Static worker config in the `use` line** — `use Oban.Worker, max_attempts: 3` is
      compile-time, frozen before any mutant could activate. Only the *dynamic*
      `MyWorker.new(args, max_attempts: 3)` options are mutable (that's `Mutare.Oban.Enqueue`).
    * **Cron schedules** — `Oban.Plugins.Cron`'s `crontab:` lives in `config/*.exs`, which
      Mutare never reads (it rewrites `lib/` source).
  """

  @doc """
  The plugin's mutators as a list, for splicing into `:mutators`:

      [mutators: [:builtins] ++ Mutare.Oban.all()]
  """
  @spec all() :: [module()]
  def all, do: [Mutare.Oban.WorkerReturn, Mutare.Oban.Enqueue]

  @doc """
  The `@behaviour`s that mark a module as an Oban worker — `Oban.Worker` and Oban Pro's
  `Oban.Pro.Worker`. A module implementing any of these has its `perform/1`/`process/1`
  return tails mutated by `Mutare.Oban.WorkerReturn`.
  """
  @spec worker_behaviours() :: [module()]
  def worker_behaviours, do: [Oban.Worker, Oban.Pro.Worker]
end
