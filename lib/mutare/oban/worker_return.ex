defmodule Mutare.Oban.WorkerReturn do
  @moduledoc """
  Swaps the **return value of an Oban worker callback** (`perform/1`, and Pro's `process/1`)
  for a *different but still valid* Oban outcome — the higher-signal analogue of
  `Mutare.Mutators.ReturnValue`'s sentinel.

  Applies only inside a module that implements `Oban.Worker` (or
  `Oban.Pro.Worker`), as recorded in the enclosing module's behaviour set
  (`context.behaviours`, gathered by Mutare from a `use Oban.Worker`'s injected
  `@behaviour`). No mutations are produced elsewhere.

  Every replacement is a **valid** Oban return with a different effect on the job's outcome.
  A survivor indicates that the suite did not detect the change in success / failure / retry /
  cancel / snooze behaviour.

  ## The swaps

      :ok                ->  {:error, :mutare}     a completed job is now retryable
      {:ok, value}       ->  {:error, :mutare}     a completed job is now retryable
      {:error, reason}   ->  :ok                   a failure is treated as success
      {:error, reason}   ->  {:cancel, reason}     a transient failure becomes a permanent cancel
      {:cancel, reason}  ->  {:error, reason}      a permanent cancel becomes retryable
      {:cancel, reason}  ->  :ok                   a cancel becomes a success
      {:snooze, seconds} ->  :ok                   a reschedule is dropped
      {:discard, reason} ->  :ok                   a legacy discard becomes a success
      {:discard, reason} ->  {:cancel, reason}
      :discard           ->  :ok                   a legacy bare discard becomes a success

  For example, **`{:error, reason}` → `:ok`** can survive if a test inserts a job that should
  fail but never asserts that the job ends up `retryable` / `discarded`.

  ## Ignore variants

  Each mutant is labelled by the Oban return it *becomes* — `ok`, `error`, or `cancel` — so a
  `# mutare:ignore[oban_worker_return:<label>]` directive can suppress one kind of swap
  without excluding the family:

      {:error, reason} # mutare:ignore[oban_worker_return:ok] best-effort, failure unasserted

  keeps the `{:error, reason}` → `{:cancel, reason}` mutant while dropping the
  swap from an error to `:ok` on that line. See `Mutare.Ignore`.

  Each mutant reuses the original `reason` operand and injects only literal control atoms, so
  every one is a **valid return that compiles** — the single metamutant build is never at
  risk. Return tails are delivered by Mutare's structural `return_replacements/2` hook, so the
  swaps also apply to returns from branch tails of a `case`/`cond`/`if`/`with` in tail
  position, as well as the clause body.

  ## Deliberately left alone

    * The `{:ok, value}`'s `value` and a `{:snooze, seconds}`'s `seconds` are dropped when
      replacing the return with `{:error, :mutare}` or `:ok`, respectively. Mutations of the
      payload itself are handled by `Mutare.Mutators`.
    * A bare `:ok` has no payload to preserve, so its only swap is to a sentinel error.
    * A bare `:cancel` tail is **not** matched: it is not a member of Oban's `t:Oban.Worker.result/0`
      union (only `:discard` has a bare legacy form). Oban logs an unknown return and completes the
      job anyway, so an `:ok` swap there would differ only by a log line — an unkillable no-op.
  """

  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :oban_worker_return

  @doc """
  The deployment requirement: `Oban.Worker` must be loadable in the Mutare process, or the
  `use Oban.Worker` expansion that provides `@behaviour Oban.Worker` cannot run. Declaring this
  requirement causes a `Mutare.EnvironmentError` at startup if Oban is not loadable.
  `Oban.Pro.Worker` is deliberately not listed because Pro is optional.
  """
  @impl Mutare.Mutator
  def required_modules, do: [Oban.Worker]

  @doc """
  The return-tag labels for `# mutare:ignore[oban_worker_return:<label>]` — each mutant
  is labelled by the Oban return it becomes: `"ok"`, `"error"`, or `"cancel"`.
  """
  @impl Mutare.Mutator
  def variants, do: ~w(ok error cancel)

  @doc """
  Classifies an emitted swap by its replacement's return tag (`c:Mutare.Mutator.variant/2`).

  Every mutant this family produces is exactly one of `:ok`, `{:error, _}`, or `{:cancel, _}`,
  so the label is derived directly from the mutated node.
  """
  @impl Mutare.Mutator
  def variant(_original, mutated) do
    case AST.unwrap_literal(mutated) do
      :ok -> "ok"
      {tag_node, _payload} -> tag_label(AST.key_atom(tag_node))
      _other -> nil
    end
  end

  defp tag_label(tag) when tag in [:error, :cancel], do: Atom.to_string(tag)
  defp tag_label(_other), do: nil

  @doc """
  Returns the alternative Oban return(s) for `tail`, but only inside a worker module (read from
  `context.behaviours`). The context-aware form of
  `c:Mutare.Mutator.Structural.return_replacements/1`.
  """
  @impl Mutare.Mutator.Structural
  def return_replacements(tail, %{behaviours: behaviours}) do
    # `AST.unwrap_literal/1` sees through the single-element block Sourceror anchors a scalar
    # atom literal in, so the bare-atom clauses below match; a tuple tail passes through.
    if worker?(behaviours), do: swaps(AST.unwrap_literal(tail)), else: []
  end

  defp worker?(behaviours),
    do: Enum.any?(Mutare.Oban.worker_behaviours(), &MapSet.member?(behaviours, &1))

  # Bare-atom tails. `:discard` is the one tag with a valid bare legacy form; a bare `:cancel`
  # is not an Oban return (Oban logs it and completes the job), so it falls through to `[]`.
  defp swaps(:ok), do: [error_tuple()]
  defp swaps(:discard), do: [ok()]

  # Two-tuple tails `{tag, payload}` — in AST a literal 2-tuple is the only thing that matches
  # this shape (everything else is a 3-element `{call, meta, args}` node), so reading the tag
  # atom off the first element is unambiguous. A non-Oban tag falls through to `[]`.
  defp swaps({tag_node, payload}), do: two_tuple(AST.key_atom(tag_node), payload)
  defp swaps(_other), do: []

  defp two_tuple(:ok, _value), do: [error_tuple()]
  defp two_tuple(:error, reason), do: [ok(), tuple(:cancel, reason)]
  defp two_tuple(:cancel, reason), do: [tuple(:error, reason), ok()]
  defp two_tuple(:snooze, _seconds), do: [ok()]
  defp two_tuple(:discard, reason), do: [ok(), tuple(:cancel, reason)]
  defp two_tuple(_tag, _payload), do: []

  defp ok, do: AST.literal(:ok)
  defp error_tuple, do: tuple(:error, AST.literal(AST.sentinel_atom()))

  # A literal 2-tuple node `{tag, payload}`: the tag as a clean-meta atom literal, the payload
  # reused verbatim. Renders `{:tag, payload}`.
  defp tuple(tag, payload), do: {AST.literal(tag), payload}
end
