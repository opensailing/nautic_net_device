defmodule RacingOrg.Tracker.Pro.RuntimeSnapshot do
  @moduledoc """
  Shared closed-runtime-snapshot validation and monotonic-time rebasing.

  Version 1 bounds serialized ages and restore elapsed time to 30 days. UTC
  restore clocks never move backward: any negative elapsed value fails closed so
  captured state cannot be rejuvenated. Callers keep their own exact snapshot
  schemas and use these helpers so age, finite-number, bounded-list, canonical
  hardware-identifier, and exact-key validation cannot drift between runtimes.
  """

  @version 1
  @max_age_ms 2_592_000_000
  @max_restore_elapsed_ms 2_592_000_000
  @max_exact_float_integer 9_007_199_254_740_991

  @spec version() :: pos_integer()
  def version, do: @version

  @spec max_age_ms() :: pos_integer()
  def max_age_ms, do: @max_age_ms

  @spec utc_ms(DateTime.t() | integer()) :: {:ok, non_neg_integer()} | :error
  def utc_ms(%DateTime{} = value) do
    case DateTime.to_unix(value, :millisecond) do
      milliseconds when milliseconds >= 0 -> {:ok, milliseconds}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def utc_ms(value) when is_integer(value) and value >= 0, do: {:ok, value}
  def utc_ms(_value), do: :error

  @spec elapsed_wall_ms(non_neg_integer(), non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def elapsed_wall_ms(captured_at_utc_ms, restored_at_utc_ms)
      when is_integer(captured_at_utc_ms) and captured_at_utc_ms >= 0 and
             is_integer(restored_at_utc_ms) and restored_at_utc_ms >= 0 do
    elapsed_ms = restored_at_utc_ms - captured_at_utc_ms

    if elapsed_ms >= 0 and elapsed_ms <= @max_restore_elapsed_ms,
      do: {:ok, elapsed_ms},
      else: :error
  end

  def elapsed_wall_ms(_captured_at_utc_ms, _restored_at_utc_ms), do: :error

  @spec timestamp_age(integer(), integer()) :: {:ok, non_neg_integer()} | :error
  def timestamp_age(timestamp_ms, captured_at_ms)
      when is_integer(timestamp_ms) and is_integer(captured_at_ms) do
    validate_age(captured_at_ms - timestamp_ms)
  end

  def timestamp_age(_timestamp_ms, _captured_at_ms), do: :error

  @spec add_elapsed(non_neg_integer(), non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def add_elapsed(age_ms, elapsed_ms)
      when is_integer(age_ms) and age_ms >= 0 and is_integer(elapsed_ms) and elapsed_ms >= 0 do
    validate_age(age_ms + elapsed_ms)
  end

  def add_elapsed(_age_ms, _elapsed_ms), do: :error

  @spec advance_capped_age(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :error
  def advance_capped_age(age_ms, elapsed_ms, cap_ms)
      when is_integer(elapsed_ms) and elapsed_ms >= 0 and is_integer(cap_ms) and cap_ms >= 0 do
    with {:ok, _age_ms} <- validate_age(age_ms),
         true <- age_ms <= cap_ms do
      {:ok, min(age_ms + elapsed_ms, cap_ms)}
    else
      _ -> :error
    end
  end

  def advance_capped_age(_age_ms, _elapsed_ms, _cap_ms), do: :error

  @spec restore_timestamp(non_neg_integer(), integer(), non_neg_integer()) :: {:ok, integer()} | :error
  def restore_timestamp(age_ms, restored_at_ms, elapsed_ms) when is_integer(restored_at_ms) do
    with {:ok, effective_age_ms} <- add_elapsed(age_ms, elapsed_ms) do
      {:ok, restored_at_ms - effective_age_ms}
    end
  end

  def restore_timestamp(_age_ms, _restored_at_ms, _elapsed_ms), do: :error

  @spec validate_age(term()) :: {:ok, non_neg_integer()} | :error
  def validate_age(age_ms)
      when is_integer(age_ms) and age_ms >= 0 and age_ms <= @max_age_ms,
      do: {:ok, age_ms}

  def validate_age(_age_ms), do: :error

  @spec validate_age_seconds(term()) :: {:ok, number()} | :error
  def validate_age_seconds(age_s) do
    if finite_non_negative?(age_s) and age_s <= @max_age_ms / 1000 do
      {:ok, age_s}
    else
      :error
    end
  end

  @spec add_elapsed_seconds(number(), non_neg_integer()) :: {:ok, number()} | :error
  def add_elapsed_seconds(age_s, elapsed_ms)
      when is_integer(elapsed_ms) and elapsed_ms >= 0 do
    validate_age_seconds(age_s + elapsed_ms / 1000)
  rescue
    _ -> :error
  end

  def add_elapsed_seconds(_age_s, _elapsed_ms), do: :error

  @spec exact_keys(term(), [term()]) :: :ok | :error
  def exact_keys(map, fields) when is_map(map) and not is_struct(map) and is_list(fields) do
    if map_size(map) == length(fields) and Enum.all?(fields, &Map.has_key?(map, &1)),
      do: :ok,
      else: :error
  end

  def exact_keys(_map, _fields), do: :error

  @doc "Validate a proper list without traversing past the configured maximum."
  @spec bounded_list(term(), non_neg_integer()) :: :ok | :error
  def bounded_list(value, maximum) when is_integer(maximum) and maximum >= 0,
    do: bounded_list(value, maximum, 0)

  def bounded_list(_value, _maximum), do: :error

  defp bounded_list([], _maximum, _count), do: :ok
  defp bounded_list([_head | _tail], maximum, count) when count >= maximum, do: :error
  defp bounded_list([_head | tail], maximum, count), do: bounded_list(tail, maximum, count + 1)
  defp bounded_list(_improper, _maximum, _count), do: :error

  @spec canonical_hardware_identifier(term()) :: :ok | :error
  def canonical_hardware_identifier(value) when is_binary(value) and byte_size(value) in 1..16 do
    if Regex.match?(~r/\A[0-9A-F]+\z/, value), do: :ok, else: :error
  end

  def canonical_hardware_identifier(_value), do: :error

  @spec finite_number?(term()) :: boolean()
  def finite_number?(value) when is_integer(value),
    do: value >= -@max_exact_float_integer and value <= @max_exact_float_integer

  def finite_number?(value) when is_float(value) do
    difference = value - value
    difference == 0
  rescue
    _ -> false
  end

  def finite_number?(_value), do: false

  @spec finite_between?(term(), number(), number()) :: boolean()
  def finite_between?(value, minimum, maximum),
    do: finite_number?(value) and value >= minimum and value <= maximum

  @spec finite_between_or_nil?(term(), number(), number()) :: boolean()
  def finite_between_or_nil?(nil, _minimum, _maximum), do: true
  def finite_between_or_nil?(value, minimum, maximum), do: finite_between?(value, minimum, maximum)

  @spec finite_non_negative?(term()) :: boolean()
  def finite_non_negative?(value), do: finite_number?(value) and value >= 0

  @spec finite_positive?(term()) :: boolean()
  def finite_positive?(value), do: finite_number?(value) and value > 0

  @spec finite_or_nil?(term()) :: boolean()
  def finite_or_nil?(nil), do: true
  def finite_or_nil?(value), do: finite_number?(value)

  @spec finite_non_negative_or_nil?(term()) :: boolean()
  def finite_non_negative_or_nil?(nil), do: true
  def finite_non_negative_or_nil?(value), do: finite_non_negative?(value)
end
