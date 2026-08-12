defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.Checkpoints do
  @moduledoc """
  Shared effect and recovery logic for the checkpoint observer commands.

  `persist_checkpoints` forces each named observer to flush its learner state to
  durable storage; `sync_checkpoints` forces each to submit its checkpoint
  upstream. Both are per-observer, idempotent, and locally owned, so the effect
  is a bounded fan-out over the requested targets and the result is the exact
  per-target outcome.

  Recovery is deliberately conservative. These effects are idempotent — running
  `persist_now` or `sync_now` twice reaches the same durable state — but after a
  crash we cannot prove from outside whether each target already ran. Rather than
  guess, recovery RE-RUNS the idempotent effect and reports it as applied: that
  is sound precisely because a second run cannot corrupt state a first run
  produced. A target that cannot be reached at all is a determinate per-target
  failure inside an applied command, never an ambiguous intent.
  """

  alias RacingOrg.Tracker.Pro.Calibration
  alias RacingOrg.Tracker.Pro.Polar
  alias RacingOrg.Tracker.Pro.WindShift

  @observers %{
    calibration: Calibration.Observer,
    polar: Polar.Observer,
    wind_shift: WindShift.Observer
  }

  @doc false
  @spec observers() :: %{atom() => module()}
  def observers, do: @observers

  @doc "Run `operation` across every requested target, collecting exact outcomes."
  @spec run(atom(), map(), term()) :: {:ok, map()}
  def run(operation, %{args: %{targets: targets}}, context)
      when operation in [:persist_now, :sync_now] and is_list(targets) do
    results =
      Map.new(targets, fn target ->
        {Atom.to_string(target), invoke(operation, target, context)}
      end)

    outcome = if Enum.all?(results, fn {_target, result} -> result == "ok" end), do: :applied, else: :failed
    {:ok, %{outcome: outcome, targets: results}}
  end

  def run(_operation, _intent_args, _context), do: {:ok, %{outcome: :failed, targets: %{}}}

  defp invoke(operation, target, context) do
    case resolve(target, context) do
      {:ok, server} -> apply_operation(operation, server)
      :error -> "unknown_target"
    end
  end

  defp apply_operation(operation, server) do
    case apply(observer_module(server), operation, [server_name(server)]) do
      :ok -> "ok"
      {:error, _reason} -> "failed"
      _other -> "failed"
    end
  rescue
    _exception -> "unavailable"
  catch
    :exit, _reason -> "unavailable"
  end

  # A target resolves either to its production module name or to an injected
  # `{module, server}` pair, so the effect is testable without the real tree.
  defp resolve(target, context) when is_map(context) do
    case Map.fetch(context, target) do
      {:ok, override} -> {:ok, override}
      :error -> default_observer(target)
    end
  end

  defp resolve(target, _context), do: default_observer(target)

  defp default_observer(target) do
    case Map.fetch(@observers, target) do
      {:ok, module} -> {:ok, module}
      :error -> :error
    end
  end

  defp observer_module({module, _server}), do: module
  defp observer_module(module), do: module

  defp server_name({_module, server}), do: server
  defp server_name(module), do: module
end
