defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.RunState do
  @moduledoc false

  @magic "RODR"
  @version 1
  @checksum_size 32
  @max_payload_size 64 * 1_024
  @checksum_domain "RacingOrg-DurableOutboxRunStateChecksum-v1"

  @spec encode(map()) :: {:ok, binary()} | {:error, atom()}
  def encode(state) when is_map(state) do
    payload = :erlang.term_to_binary(state, [:deterministic])
    payload_size = byte_size(payload)

    if payload_size <= @max_payload_size do
      checksum = checksum(payload_size, payload)
      {:ok, <<@magic, @version, payload_size::32, checksum::binary, payload::binary>>}
    else
      {:error, :run_state_too_large}
    end
  end

  def encode(_state), do: {:error, :invalid_run_state}

  @spec decode(binary()) :: {:ok, map()} | {:error, atom()}
  def decode(<<@magic, @version, payload_size::32, stored_checksum::binary-size(@checksum_size), rest::binary>>) do
    cond do
      payload_size > @max_payload_size ->
        {:error, :run_state_too_large}

      byte_size(rest) < payload_size ->
        {:error, :incomplete_run_state}

      byte_size(rest) > payload_size ->
        {:error, :trailing_run_state_bytes}

      true ->
        with :ok <- validate_checksum(stored_checksum, checksum(payload_size, rest)),
             {:ok, state} <- decode_payload(rest) do
          {:ok, state}
        end
    end
  end

  def decode(<<@magic, version, _rest::binary>>) when version != @version,
    do: {:error, :unsupported_run_state_version}

  def decode(binary) when is_binary(binary) and byte_size(binary) < 5,
    do: {:error, :incomplete_run_state}

  def decode(_binary), do: {:error, :invalid_run_state}

  defp decode_payload(<<131, 80, _rest::binary>>), do: {:error, :compressed_run_state}

  defp decode_payload(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      state when is_map(state) -> {:ok, state}
      _other -> {:error, :invalid_run_state}
    end
  rescue
    _exception -> {:error, :invalid_run_state}
  catch
    _kind, _reason -> {:error, :invalid_run_state}
  end

  defp checksum(payload_size, payload) do
    :crypto.hash(:sha256, [@checksum_domain, <<@version, payload_size::32>>, payload])
  end

  defp validate_checksum(checksum, checksum), do: :ok
  defp validate_checksum(_stored, _expected), do: {:error, :run_state_checksum_mismatch}
end
