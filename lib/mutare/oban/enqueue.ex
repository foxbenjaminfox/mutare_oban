defmodule Mutare.Oban.Enqueue do
  @moduledoc """
  Mutates the **enqueue options** of an Oban job — the keyword options passed when a job is
  built (`MyWorker.new(args, max_attempts: 3, unique: [...], schedule_in: 60)`). These options
  encode the job's retry / dedup / scheduling *policy*, so dropping or weakening one asks the
  suite a pointed question.

  ## The mutations

      max_attempts: n  (n ≠ 1)  ->  max_attempts: 1   no retries — is the retry asserted?
      unique: [...]             ->  (dropped)          dedup removed — is the dupe caught?
      schedule_in: _            ->  (dropped)          runs now, not later — is the delay asserted?
      scheduled_at: _           ->  (dropped)          runs now, not later

  Each is a single mutant, delivered in place by Mutare's selector, and compile-safe by
  construction (dropping a keyword pair or substituting the literal `1` always yields a legal
  keyword list — even the empty `[]`, a valid second argument to `new/2`).

  Each mutant is a `Mutare.Mutator.Mutation` tagged with the option it attacks as its ignore
  variant — so `# mutare:ignore[oban_enqueue:unique]` suppresses just the dedup drop on that
  line (see `Mutare.Ignore`) — and carries a report note saying what a survivor leaves
  unasserted.

  ## How it matches

  It matches the **`new/N` call** (not the keyword list — Mutare descends trailing keyword
  options as individual call arguments, never offering the list as a single node), resolving it
  through `Mutare.Calls.resolved_call/1` so the direct, aliased, and piped
  (`args |> MyWorker.new(opts)`) forms all match, and rebuilds the call with the mutated options
  in the form the source wrote. It fires on **any** module's `new` whose options carry one of
  the keys it mutates (`max_attempts`, `unique`, `schedule_in`, `scheduled_at`) — Oban-distinctive
  enough that a false positive is unlikely, and would at worst rebuild an equivalent call
  elsewhere, never miscompile.

  This intentionally covers only the **dynamic** `new/2` options. Static config in the
  `use Oban.Worker` line is compile-time and unreachable — see `Mutare.Oban`.
  """

  @behaviour Mutare.Mutator

  alias Mutare.AST
  alias Mutare.Calls
  alias Mutare.Mutator.Mutation

  # The options this mutator acts on; also the witnesses that a `new/N` call is (probably) an
  # Oban enqueue. `unique`/`schedule_in`/`scheduled_at` are dropped; `max_attempts` is capped.
  @relevant ~w(max_attempts unique schedule_in scheduled_at)a
  @dropped ~w(unique schedule_in scheduled_at)a

  @impl Mutare.Mutator
  def name, do: :oban_enqueue

  @doc """
  The attacked-option vocabulary for `# mutare:ignore[oban_enqueue:<label>]` — each mutant is
  tagged at production with the key it caps or drops.
  """
  @impl Mutare.Mutator
  def variants, do: @relevant

  @impl Mutare.Mutator
  def mutate(node) do
    case Calls.resolved_call(node) do
      {_module, :new, args, rebuild} -> mutate_new(args, rebuild)
      _other -> :skip
    end
  end

  # Find the (last) keyword-list argument carrying an Oban option, mutate it, and rebuild the
  # call around each mutant. Handles the direct `new(args, opts)` and piped `args |> new(opts)`
  # shapes alike — in the latter `args` is just `[opts]`. Each mutant is tagged with the
  # attacked key (its ignore variant) and a survivor note.
  defp mutate_new(args, rebuild) do
    with {index, opts} <- find_opts(args),
         [_ | _] = mutations <- opts_mutations(opts) do
      for {key, mutated} <- mutations do
        Mutation.new(rebuild.(:new, List.replace_at(args, index, mutated)),
          variant: key,
          note: note(key)
        )
      end
    else
      _no_opts_or_no_mutations -> :skip
    end
  end

  # The guidance shown next to a surviving mutant in the report: what the weakened policy
  # means, phrased as the assertion the suite is missing.
  defp note(:max_attempts), do: "max_attempts capped to 1 — no test asserts the retry"
  defp note(:unique), do: "unique dropped — no test catches the duplicate job"
  defp note(:schedule_in), do: "schedule_in dropped — no test asserts the delay"
  defp note(:scheduled_at), do: "scheduled_at dropped — no test asserts the scheduled time"

  defp find_opts(args) do
    args
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {arg, index} ->
      if oban_opts?(arg), do: {index, arg}
    end)
  end

  defp oban_opts?(opts) when is_list(opts),
    do: keyword?(opts) and Enum.any?(@relevant, &has_key?(opts, &1))

  defp oban_opts?(_node), do: false

  # Each mutation as a `{attacked_key, mutated_opts}` pair, so the caller can tag the rebuilt
  # call with the key it attacks.
  defp opts_mutations(opts) do
    drops = for key <- @dropped, has_key?(opts, key), do: {key, drop(opts, key)}
    drops ++ cap_attempts(opts)
  end

  # Remove the `key: value` pair — the option is no longer applied.
  defp drop(opts, key), do: Enum.reject(opts, &(pair_key(&1) == key))

  # `max_attempts: n` -> `max_attempts: 1`, unless already 1 (an equivalent no-op). A non-literal
  # value (`max_attempts: @retries`) is left alone — we can't prove it isn't 1.
  defp cap_attempts(opts) do
    case find(opts, :max_attempts) do
      {_key, value} ->
        case AST.literal_value(value) do
          {:ok, 1} -> []
          {:ok, _other} -> [{:max_attempts, put(opts, :max_attempts, AST.literal(1))}]
          :error -> []
        end

      nil ->
        []
    end
  end

  # ---- keyword-list helpers over Sourceror pairs `{key_node, value_node}` ----

  defp keyword?([]), do: false
  defp keyword?(opts), do: Enum.all?(opts, &pair?/1)

  defp pair?({key, _value}), do: AST.key_atom(key) != nil
  defp pair?(_node), do: false

  defp pair_key({key, _value}), do: AST.key_atom(key)
  defp pair_key(_node), do: nil

  defp has_key?(opts, key), do: Enum.any?(opts, &(pair_key(&1) == key))

  defp find(opts, key), do: Enum.find(opts, &(pair_key(&1) == key))

  defp put(opts, key, value) do
    Enum.map(opts, fn
      {k, _v} = pair -> if AST.key_atom(k) == key, do: {k, value}, else: pair
      other -> other
    end)
  end
end
