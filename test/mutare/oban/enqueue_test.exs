defmodule Mutare.Oban.EnqueueTest do
  use ExUnit.Case, async: true

  import Mutare.Test

  @mutators [Mutare.Oban.Enqueue]

  defp enqueue(src), do: diffs_for(src, @mutators, :oban_enqueue)
  defp mutateds(src), do: enqueue(src) |> Enum.map(fn {_original, mutated} -> mutated end)

  defp jobs(call) do
    """
    defmodule MyApp.Jobs do
      def schedule(id) do
        #{call}
      end
    end
    """
  end

  test "caps max_attempts to 1, drops unique and schedule_in" do
    muts =
      mutateds(
        jobs(
          "MyApp.Worker.new(%{id: id}, max_attempts: 5, unique: [period: 60], schedule_in: 30)"
        )
      )

    assert Enum.any?(muts, &(&1 =~ "max_attempts: 1"))
    assert Enum.any?(muts, &(not (&1 =~ "unique")))
    assert Enum.any?(muts, &(not (&1 =~ "schedule_in")))
    assert length(muts) == 3
  end

  test "drops scheduled_at" do
    muts = mutateds(jobs("MyApp.Worker.new(%{}, scheduled_at: at, max_attempts: 1)"))

    # max_attempts is already 1 (no-op, skipped), so the only mutation is dropping scheduled_at:
    # the rebuilt call keeps max_attempts but no longer mentions scheduled_at.
    assert [mutated] = muts
    assert mutated =~ "max_attempts: 1"
    refute mutated =~ "scheduled_at"
  end

  test "does not cap max_attempts when it is already 1 (equivalent no-op avoided)" do
    muts = mutateds(jobs("MyApp.Worker.new(%{}, max_attempts: 1)"))
    assert muts == []
  end

  test "does not fire on a keyword list with no Oban-distinctive key" do
    src = """
    defmodule Plain do
      def opts, do: [timeout: 5_000, label: :foo]
    end
    """

    assert enqueue(src) == []
  end

  test "leaves a non-literal max_attempts alone" do
    muts = mutateds(jobs("MyApp.Worker.new(%{}, max_attempts: @retries, unique: [period: 60])"))

    # @retries can't be proven ≠ 1, so only the unique drop fires.
    assert length(muts) == 1
    assert Enum.all?(muts, &(not (&1 =~ "unique")))
  end

  test "every mutant compiles" do
    src =
      jobs("MyApp.Worker.new(%{id: id}, max_attempts: 5, unique: [period: 60], schedule_in: 30)")

    assert_metamutant_compiles(src, @mutators)
  end

  describe "variant tags and notes" do
    test "declares the attacked-option vocabulary" do
      assert Mutare.Oban.Enqueue.variants() ==
               ~w(max_attempts unique schedule_in scheduled_at)a
    end

    test "each mutant is tagged with the option it attacks and carries a survivor note" do
      src = jobs("MyApp.Worker.new(%{id: id}, max_attempts: 5, unique: [period: 60])")
      result = Mutare.transform_string(src, mutators: @mutators)

      by_variant = Map.new(result.mutants, &{&1.variant, &1})

      assert %{mutated_code: capped, note: retry_note} = by_variant[["max_attempts"]]
      assert capped =~ "max_attempts: 1"
      assert retry_note =~ "retry"

      assert %{mutated_code: dropped, note: dedup_note} = by_variant[["unique"]]
      refute dropped =~ "unique"
      assert dedup_note =~ "duplicate"
    end

    test "[oban_enqueue:unique] suppresses only the dedup drop" do
      src =
        jobs(
          "MyApp.Worker.new(%{id: id}, max_attempts: 5, unique: [period: 60]) " <>
            "# mutare:ignore[oban_enqueue:unique]"
        )

      result = Mutare.transform_string(src, mutators: @mutators)

      ignored? = Map.new(result.mutants, &{&1.variant, &1.ignored})

      assert ignored?[["unique"]] == true
      assert ignored?[["max_attempts"]] == false
    end
  end
end
