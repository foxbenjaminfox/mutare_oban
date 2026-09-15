defmodule Mutare.Oban do
  @moduledoc """
  Mutation-testing mutators for [Oban](https://hexdocs.pm/oban) — a plugin for
  [Mutare](https://hexdocs.pm/mutare).

  This plugin targets two aspects of Oban worker behaviour that ordinary value mutations
  do not directly test:

    * the **return value of `perform/1`** — which determines whether a job
      completes, retries, cancels, or snoozes; and
    * the **enqueue options** (`max_attempts:`, `unique:`, `schedule_in:`, …) — the
      retry / dedup / scheduling policy.

  The mutations replace valid Oban returns with other valid returns and change enqueue options.
  A **surviving** mutant indicates that the suite did not detect the changed behaviour — for
  example, a failed job completing without a retry, a duplicate job, or a missing reschedule.

  It is two independent `Mutare.Mutator`s, listed alongside the built-ins:

      # .mutare.exs
      [mutators: [:builtins, Mutare.Oban.WorkerReturn, Mutare.Oban.Enqueue]]

  or, equivalently, splicing the convenience list:

      [mutators: [:builtins] ++ Mutare.Oban.all()]

  (`:builtins` keeps Mutare's default families and *adds* these; omit it to run the Oban
  mutators alone.) Mutations are recorded under their respective report families —
  `:oban_worker_return` and `:oban_enqueue` — and either mutator can be enabled alone.

  Both families declare **ignore-variant labels**, so a `# mutare:ignore[family:label]`
  directive can suppress one kind of mutant without excluding the family — e.g.
  `# mutare:ignore[oban_worker_return:ok]` keeps the cancel swap but drops the
  swap from an error to `:ok` on that line. `Mutare.Oban.WorkerReturn` labels each swap by
  the return it becomes (`ok` / `error` / `cancel`); `Mutare.Oban.Enqueue` labels each
  mutation by the option it changes (`max_attempts` / `unique` / `schedule_in` /
  `scheduled_at`) and includes a report note describing an assertion that could detect the change.

  ## What fits cleanly, and what doesn't

  `Mutare.Oban.WorkerReturn` applies only inside modules that implement
  `Oban.Worker` (or `Oban.Pro.Worker`). Mutare detects that through its `use`-expansion —
  `use Oban.Worker` injects `@behaviour Oban.Worker` — so **Oban must be loadable in the
  Mutare process** (it is, since `mix mutare` runs with the target's deps on the path).
  `Mutare.Oban.WorkerReturn` declares that requirement via
  `c:Mutare.Mutator.required_modules/0`, so a run where Oban is absent fails at
  startup with a `Mutare.EnvironmentError`.

  Two things are deliberately *out of scope* because they are not runtime positions Mutare can
  splice a selector into:

    * **Static worker config in the `use` line** — `use Oban.Worker, max_attempts: 3` is
      compile-time, frozen before any mutant can be activated. Only the *dynamic*
      `MyWorker.new(args, max_attempts: 3)` options are mutable (that's `Mutare.Oban.Enqueue`).
    * **Cron schedules** — `Oban.Plugins.Cron`'s `crontab:` is configured in `config/*.exs`, which
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
