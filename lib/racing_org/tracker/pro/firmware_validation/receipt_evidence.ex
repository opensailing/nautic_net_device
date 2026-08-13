defmodule RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptEvidence do
  @moduledoc """
  Monotonic evidence of authenticated receipt round trips.

  The ChannelClient records a class each time the backend's authenticated
  `delivery_receipt` retires durable entries: `:control` for every receipt
  (the control plane demonstrably works end to end) and `:telemetry`
  additionally for the telemetry stream. The firmware health gate and the
  Wi-Fi reconnect confirmation read the evidence; absence or staleness is
  `:pending`, never a crash. Timestamps live in a lazily created `:atomics`
  block (the `:persistent_term` entry is written once), so the hot receipt
  path never triggers a global term scan.
  """

  @classes %{control: 1, telemetry: 3}
  @slot_count 4
  @default_freshness_ms 900_000
  @default_key __MODULE__

  @type class :: :control | :telemetry

  @doc "Record one authenticated round trip for `class`. Unknown classes are inert."
  @spec record(atom(), keyword()) :: :ok
  def record(class, opts \\ []) do
    case Map.fetch(@classes, class) do
      {:ok, slot} ->
        ref = counters(opts)
        :atomics.put(ref, slot, System.monotonic_time(:millisecond))
        :atomics.put(ref, slot + 1, 1)
        :ok

      :error ->
        :ok
    end
  end

  @doc "Return `:succeeded` when `class` was recorded within the freshness window."
  @spec status(atom(), keyword()) :: :succeeded | :pending
  def status(class, opts \\ []) do
    freshness_ms = Keyword.get(opts, :freshness_ms, @default_freshness_ms)

    case recorded_at(class, opts) do
      {:ok, recorded_at_ms} ->
        if System.monotonic_time(:millisecond) - recorded_at_ms <= freshness_ms,
          do: :succeeded,
          else: :pending

      :empty ->
        :pending
    end
  end

  @doc "Whether `class` was recorded at or after the monotonic anchor `since_ms`."
  @spec recorded_after?(atom(), integer(), keyword()) :: boolean()
  def recorded_after?(class, since_ms, opts \\ []) when is_integer(since_ms) do
    case recorded_at(class, opts) do
      {:ok, recorded_at_ms} -> recorded_at_ms >= since_ms
      :empty -> false
    end
  end

  @doc false
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    :persistent_term.erase(Keyword.get(opts, :key, @default_key))
    :ok
  end

  defp recorded_at(class, opts) do
    with {:ok, slot} <- Map.fetch(@classes, class),
         ref when ref != nil <- :persistent_term.get(Keyword.get(opts, :key, @default_key), nil),
         1 <- :atomics.get(ref, slot + 1) do
      {:ok, :atomics.get(ref, slot)}
    else
      _absent -> :empty
    end
  end

  defp counters(opts) do
    key = Keyword.get(opts, :key, @default_key)

    case :persistent_term.get(key, nil) do
      nil ->
        ref = :atomics.new(@slot_count, signed: true)
        :persistent_term.put(key, ref)
        :persistent_term.get(key)

      ref ->
        ref
    end
  end
end
