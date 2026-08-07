defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical do
  @moduledoc """
  Deterministic, non-JSON canonical value encoding for desired-state section content.

  Plain binaries are UTF-8 text. Arbitrary bytes require the explicit `bytes/1` wrapper,
  so text and byte strings can never hash to the same type accidentally.
  """

  import Bitwise

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @max_depth 16
  @max_key_size 128
  @max_collection_count 65_535
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @i64_min -0x8000_0000_0000_0000
  @negative_zero_bits 0x8000_0000_0000_0000
  @float_exponent_mask 0x7FF0_0000_0000_0000

  defmodule Bytes do
    @moduledoc "Explicit canonical byte-string wrapper."
    @enforce_keys [:data]
    defstruct [:data]

    @type t :: %__MODULE__{data: binary()}
  end

  @type value ::
          nil
          | boolean()
          | integer()
          | float()
          | binary()
          | atom()
          | Bytes.t()
          | [value()]
          | %{optional(binary() | atom()) => value()}

  @doc "Wrap arbitrary binary data as canonical bytes rather than UTF-8 text."
  @spec bytes(binary()) :: Bytes.t()
  def bytes(value) when is_binary(value), do: %Bytes{data: value}

  @doc "Encode one value and reject anything outside the frozen canonical grammar."
  @spec encode(value()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    with {:ok, encoded} <- encode_value(value, 0) do
      binary = IO.iodata_to_binary(encoded)

      if byte_size(binary) <= Contract.max_section_size() do
        {:ok, binary}
      else
        {:error, :value_too_large}
      end
    end
  rescue
    ArgumentError -> {:error, :invalid_value}
  end

  @doc "Strictly decode one canonical value with no trailing bytes."
  @spec decode(binary()) :: {:ok, value()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    cond do
      byte_size(binary) > Contract.max_section_size() ->
        {:error, :value_too_large}

      true ->
        with {:ok, value, <<>>} <- parse_value(binary, 0) do
          {:ok, value}
        else
          {:ok, _value, _trailing} -> {:error, :trailing_bytes}
          {:error, _reason} = error -> error
        end
    end
  end

  def decode(_), do: {:error, :invalid_value}

  @doc "SHA-256 the exact canonical bytes for a value."
  @spec hash(value()) :: {:ok, binary()} | {:error, term()}
  def hash(value) do
    with {:ok, encoded} <- encode(value), do: {:ok, :crypto.hash(:sha256, encoded)}
  end

  @doc "Reject missing or unknown map fields after atom-to-string and NFC normalization."
  @spec validate_fields(map(), [binary() | atom()], [binary() | atom()]) :: :ok | {:error, term()}
  def validate_fields(value, required, optional)
      when is_map(value) and is_list(required) and is_list(optional) do
    with {:ok, actual} <- normalized_key_set(Map.keys(value)),
         {:ok, required} <- normalized_key_set(required),
         {:ok, optional} <- normalized_key_set(optional) do
      missing = required -- actual
      unknown = actual -- (required ++ optional)

      cond do
        missing != [] -> {:error, {:missing_fields, Enum.sort(missing)}}
        unknown != [] -> {:error, {:unknown_fields, Enum.sort(unknown)}}
        true -> :ok
      end
    end
  end

  def validate_fields(_, _, _), do: {:error, :invalid_fields}

  defp encode_value(nil, _depth), do: {:ok, <<0x00>>}
  defp encode_value(false, _depth), do: {:ok, <<0x01>>}
  defp encode_value(true, _depth), do: {:ok, <<0x02>>}

  defp encode_value(value, _depth) when is_integer(value) and value >= 0 and value <= @u64_max,
    do: {:ok, <<0x03, value::unsigned-big-integer-size(64)>>}

  defp encode_value(value, _depth) when is_integer(value) and value >= @i64_min and value < 0,
    do: {:ok, <<0x04, value::signed-big-integer-size(64)>>}

  defp encode_value(value, _depth) when is_integer(value), do: {:error, :integer_out_of_range}

  defp encode_value(value, _depth) when is_float(value) do
    <<bits::unsigned-big-integer-size(64)>> = <<value::float-big-size(64)>>

    cond do
      (bits &&& @float_exponent_mask) == @float_exponent_mask ->
        {:error, :non_finite_float}

      bits == @negative_zero_bits ->
        {:ok, <<0x05, 0::64>>}

      true ->
        {:ok, <<0x05, bits::64>>}
    end
  end

  defp encode_value(%Bytes{data: data}, _depth) when is_binary(data) do
    if byte_size(data) + 5 <= Contract.max_section_size() do
      {:ok, [<<0x06, byte_size(data)::32>>, data]}
    else
      {:error, :value_too_large}
    end
  end

  defp encode_value(value, depth) when is_binary(value), do: encode_text(value, depth)

  defp encode_value(value, depth) when is_atom(value) do
    value
    |> Atom.to_string()
    |> encode_text(depth)
  end

  defp encode_value(value, depth) when is_list(value) do
    with :ok <- ensure_depth(depth),
         :ok <- ensure_proper_list(value),
         count <- length(value),
         :ok <- ensure_collection_count(count),
         {:ok, encoded} <- encode_list(value, depth + 1, []) do
      {:ok, [<<0x08, count::32>>, Enum.reverse(encoded)]}
    end
  end

  defp encode_value(value, depth) when is_map(value) do
    with :ok <- ensure_depth(depth),
         :ok <- ensure_collection_count(map_size(value)),
         {:ok, entries} <- normalize_map_entries(value),
         {:ok, encoded} <- encode_map(entries, depth + 1, []) do
      {:ok, [<<0x09, length(entries)::32>>, Enum.reverse(encoded)]}
    end
  end

  defp encode_value(_value, _depth), do: {:error, :unsupported_value_type}

  defp encode_text(value, _depth) do
    with {:ok, normalized} <- normalize_text(value) do
      if byte_size(normalized) + 5 <= Contract.max_section_size() do
        {:ok, [<<0x07, byte_size(normalized)::32>>, normalized]}
      else
        {:error, :value_too_large}
      end
    end
  end

  defp encode_list([], _depth, acc), do: {:ok, acc}

  defp encode_list([value | rest], depth, acc) do
    with {:ok, encoded} <- encode_value(value, depth) do
      encode_list(rest, depth, [encoded | acc])
    end
  end

  defp encode_map([], _depth, acc), do: {:ok, acc}

  defp encode_map([{key, value} | rest], depth, acc) do
    with {:ok, encoded_value} <- encode_value(value, depth) do
      encode_map(rest, depth, [[<<byte_size(key)::16>>, key, encoded_value] | acc])
    end
  end

  defp normalize_map_entries(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn {key, entry_value}, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, normalized} -> {:cont, {:ok, [{normalized, entry_value} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        sorted = Enum.sort_by(entries, &elem(&1, 0))

        if duplicate_sorted_key?(sorted) do
          {:error, :duplicate_map_key}
        else
          {:ok, sorted}
        end

      error ->
        error
    end
  end

  defp normalized_key_set(keys) do
    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case normalize_key(key) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} ->
        unique = Enum.uniq(normalized)

        if length(unique) == length(normalized) do
          {:ok, Enum.sort(unique)}
        else
          {:error, :duplicate_map_key}
        end

      error ->
        error
    end
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    with {:ok, normalized} <- normalize_text(key) do
      if byte_size(normalized) <= @max_key_size do
        {:ok, normalized}
      else
        {:error, :map_key_too_long}
      end
    end
  end

  defp normalize_key(_), do: {:error, :invalid_map_key}

  defp normalize_text(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      true -> {:ok, String.normalize(value, :nfc)}
    end
  end

  defp duplicate_sorted_key?([{key, _}, {key, _} | _]), do: true
  defp duplicate_sorted_key?([_ | rest]), do: duplicate_sorted_key?(rest)
  defp duplicate_sorted_key?([]), do: false

  defp parse_value(<<0x00, rest::binary>>, _depth), do: {:ok, nil, rest}
  defp parse_value(<<0x01, rest::binary>>, _depth), do: {:ok, false, rest}
  defp parse_value(<<0x02, rest::binary>>, _depth), do: {:ok, true, rest}

  defp parse_value(<<0x03, value::unsigned-big-integer-size(64), rest::binary>>, _depth),
    do: {:ok, value, rest}

  defp parse_value(<<0x04, value::signed-big-integer-size(64), rest::binary>>, _depth)
       when value < 0,
       do: {:ok, value, rest}

  defp parse_value(<<0x04, _value::binary-size(8), _rest::binary>>, _depth),
    do: {:error, :noncanonical_negative_integer}

  defp parse_value(<<0x05, bits::unsigned-big-integer-size(64), rest::binary>>, _depth) do
    cond do
      (bits &&& @float_exponent_mask) == @float_exponent_mask ->
        {:error, :non_finite_float}

      bits == @negative_zero_bits ->
        {:error, :negative_zero}

      true ->
        <<value::float-big-size(64)>> = <<bits::64>>
        {:ok, value, rest}
    end
  end

  defp parse_value(<<0x06, length::32, rest::binary>>, _depth) when byte_size(rest) >= length do
    <<value::binary-size(length), trailing::binary>> = rest
    {:ok, %Bytes{data: value}, trailing}
  end

  defp parse_value(<<0x07, length::32, rest::binary>>, _depth) when byte_size(rest) >= length do
    <<value::binary-size(length), trailing::binary>> = rest

    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      String.normalize(value, :nfc) != value -> {:error, :noncanonical_unicode}
      true -> {:ok, value, trailing}
    end
  end

  defp parse_value(<<0x08, count::32, rest::binary>>, depth) do
    with :ok <- ensure_depth(depth),
         :ok <- ensure_collection_count(count),
         {:ok, values, trailing} <- parse_list(rest, count, depth + 1, []) do
      {:ok, Enum.reverse(values), trailing}
    end
  end

  defp parse_value(<<0x09, count::32, rest::binary>>, depth) do
    with :ok <- ensure_depth(depth),
         :ok <- ensure_collection_count(count),
         {:ok, entries, trailing} <- parse_map(rest, count, depth + 1, nil, []) do
      {:ok, Map.new(entries), trailing}
    end
  end

  defp parse_value(<<tag, _rest::binary>>, _depth) when tag > 0x09,
    do: {:error, :unknown_type_tag}

  defp parse_value(_binary, _depth), do: {:error, :truncated}

  defp parse_list(rest, 0, _depth, acc), do: {:ok, acc, rest}

  defp parse_list(rest, count, depth, acc) do
    with {:ok, value, trailing} <- parse_value(rest, depth) do
      parse_list(trailing, count - 1, depth, [value | acc])
    end
  end

  defp parse_map(rest, 0, _depth, _previous, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_map(<<length::16, rest::binary>>, count, depth, previous, acc)
       when byte_size(rest) >= length do
    <<key::binary-size(length), after_key::binary>> = rest

    with :ok <- validate_decoded_key(key),
         :ok <- validate_key_order(previous, key),
         {:ok, value, trailing} <- parse_value(after_key, depth) do
      parse_map(trailing, count - 1, depth, key, [{key, value} | acc])
    end
  end

  defp parse_map(_rest, _count, _depth, _previous, _acc), do: {:error, :truncated}

  defp validate_decoded_key(key) do
    cond do
      byte_size(key) > @max_key_size -> {:error, :map_key_too_long}
      not String.valid?(key) -> {:error, :invalid_utf8}
      String.normalize(key, :nfc) != key -> {:error, :noncanonical_unicode}
      true -> :ok
    end
  end

  defp validate_key_order(nil, _key), do: :ok
  defp validate_key_order(previous, key) when previous == key, do: {:error, :duplicate_map_key}
  defp validate_key_order(previous, key) when previous < key, do: :ok
  defp validate_key_order(_previous, _key), do: {:error, :map_keys_out_of_order}

  defp ensure_depth(depth) when depth + 1 <= @max_depth, do: :ok
  defp ensure_depth(_depth), do: {:error, :max_depth_exceeded}

  defp ensure_collection_count(count) when count <= @max_collection_count, do: :ok
  defp ensure_collection_count(_count), do: {:error, :collection_too_large}

  defp ensure_proper_list([]), do: :ok
  defp ensure_proper_list([_ | rest]), do: ensure_proper_list(rest)
  defp ensure_proper_list(_), do: {:error, :improper_list}
end
