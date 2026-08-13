defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Registry do
  @moduledoc """
  The closed registry of supported durable command types and their providers.

  A command payload is one canonical `%{"type" => ..., "args" => ...}` envelope.
  Decoding never creates atoms from untrusted text: an unrecognized type resolves
  to `{:error, :unsupported_command}` so the ledger records a terminal outcome
  instead of admitting an intent nothing can execute or recover.

  Every registered type carries exactly one provider module implementing:

    * `execute(intent, context)` — run the external effect exactly once,
      returning `{:ok, result_term}` for a determinate outcome (including a
      determinate failure, which is still an APPLIED command) or
      `{:error, reason}` when the effect could not be attempted at all.
    * `recover(intent, context)` — after a restart that found this intent
      pending, prove what happened: `{:applied, result_term}`,
      `{:not_applied, proof}`, or `:ambiguous` when neither can be proven.
    * `with_non_application_lease/5` — the Store's non-application lease
      contract, held across the durable rejection transition.
  """

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Provider
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical

  @max_command_result_size Contract.max_command_result_size()

  # {type, provider, reserved_result_bytes}. The reservation is the durable
  # budget the ledger admits BEFORE the effect runs, so it must be an upper bound
  # on every result the provider can encode.
  @commands [
    {:noop, Provider.Noop, 512},
    {:persist_checkpoints, Provider.PersistCheckpoints, 1_024},
    {:sync_checkpoints, Provider.SyncCheckpoints, 1_024}
  ]

  @retired_recovery_verifiers %{
    validate_firmware: {Provider.ValidateFirmware, nil}
  }

  @command_types @commands |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  @provider_by_type Map.new(@commands, fn {type, module, _reserved} -> {type, module} end)
  @reserved_by_type Map.new(@commands, fn {type, _module, reserved} -> {type, reserved} end)
  @type_by_name Map.new(@commands, fn {type, _module, _reserved} -> {Atom.to_string(type), type} end)

  # Checkpoint kinds are the only argument vocabulary any registered command
  # takes, and they too are a closed set resolved without creating atoms.
  @checkpoint_targets Contract.checkpoint_kinds() |> Enum.map(&elem(&1, 0))
  @target_by_name Map.new(@checkpoint_targets, &{Atom.to_string(&1), &1})
  @max_targets length(@checkpoint_targets)

  @envelope_keys ["args", "type"]

  @type command_type :: atom()

  @doc "Every supported command type, sorted."
  @spec command_types() :: [command_type()]
  def command_types, do: @command_types

  @doc "The provider module owning one command type's effect and recovery."
  @spec provider(term()) :: {:ok, module()} | {:error, :unsupported_command}
  def provider(type) when is_atom(type) do
    case Map.fetch(@provider_by_type, type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unsupported_command}
    end
  end

  def provider(_type), do: {:error, :unsupported_command}

  @doc "The `Store` verifier map for supported types and read-only recovery of retired intents."
  @spec recovery_verifiers() :: %{command_type() => {module(), nil}}
  def recovery_verifiers do
    @retired_recovery_verifiers
    |> Map.merge(Map.new(@commands, fn {type, module, _reserved} -> {type, {module, nil}} end))
  end

  @doc """
  Decode one command payload into its closed `%{type: atom(), args: map()}` form.

  Never raises and never creates an atom from payload text.
  """
  @spec decode_payload(binary()) :: {:ok, %{type: command_type(), args: map()}} | {:error, term()}
  def decode_payload(payload) when is_binary(payload) do
    with {:ok, envelope} <- Canonical.decode(payload),
         :ok <- envelope_shape(envelope),
         {:ok, type} <- resolve_name(Map.fetch!(envelope, "type")),
         {:ok, args} <- decode_args(type, Map.fetch!(envelope, "args")) do
      {:ok, %{type: type, args: args}}
    end
  rescue
    _exception -> {:error, :invalid_command_payload}
  catch
    _kind, _reason -> {:error, :invalid_command_payload}
  end

  def decode_payload(_payload), do: {:error, :invalid_command_payload}

  @doc "Resolve one decoded payload to its type and durable result reservation."
  @spec resolve_type(term()) ::
          {:ok, command_type(), non_neg_integer()} | {:error, :unsupported_command}
  def resolve_type(%{type: type, args: args}) when is_atom(type) and is_map(args) do
    case Map.fetch(@reserved_by_type, type) do
      {:ok, reserved} -> {:ok, type, reserved}
      :error -> {:error, :unsupported_command}
    end
  end

  def resolve_type(_decoded), do: {:error, :unsupported_command}

  @doc """
  Canonically encode one provider result and refuse anything that would exceed
  the type's admitted reservation.
  """
  @spec encode_result(command_type(), term()) :: {:ok, binary()} | {:error, term()}
  def encode_result(type, result) do
    with {:ok, reserved} <- reservation(type),
         {:ok, bytes} <- Canonical.encode(result) do
      cond do
        byte_size(bytes) > reserved -> {:error, :command_result_reservation_exceeded}
        byte_size(bytes) > @max_command_result_size -> {:error, :command_result_too_large}
        true -> {:ok, bytes}
      end
    end
  end

  @doc "The durable result reservation admitted for one command type."
  @spec reservation(term()) :: {:ok, non_neg_integer()} | {:error, :unsupported_command}
  def reservation(type) when is_atom(type) do
    case Map.fetch(@reserved_by_type, type) do
      {:ok, reserved} -> {:ok, reserved}
      :error -> {:error, :unsupported_command}
    end
  end

  def reservation(_type), do: {:error, :unsupported_command}

  defp envelope_shape(envelope) when is_map(envelope) do
    if Enum.sort(Map.keys(envelope)) == @envelope_keys,
      do: :ok,
      else: {:error, :invalid_command_payload}
  end

  defp envelope_shape(_envelope), do: {:error, :invalid_command_payload}

  defp resolve_name(name) when is_binary(name) do
    case Map.fetch(@type_by_name, name) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unsupported_command}
    end
  end

  defp resolve_name(_name), do: {:error, :unsupported_command}

  defp decode_args(type, args) when type in [:persist_checkpoints, :sync_checkpoints] do
    with true <- is_map(args) and Map.keys(args) == ["targets"],
         {:ok, targets} <- decode_targets(Map.fetch!(args, "targets")) do
      {:ok, %{targets: targets}}
    else
      false -> {:error, :invalid_command_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp decode_args(_type, args) when is_map(args) and map_size(args) == 0, do: {:ok, %{}}
  defp decode_args(_type, _args), do: {:error, :invalid_command_arguments}

  defp decode_targets(names) when is_list(names) do
    with true <- names != [] and length(names) <= @max_targets,
         {:ok, targets} <- resolve_targets(names, []),
         true <- targets == Enum.uniq(targets) do
      {:ok, targets}
    else
      false -> {:error, :invalid_command_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp decode_targets(_names), do: {:error, :invalid_command_arguments}

  defp resolve_targets([], acc), do: {:ok, Enum.reverse(acc)}

  defp resolve_targets([name | rest], acc) when is_binary(name) do
    case Map.fetch(@target_by_name, name) do
      {:ok, target} -> resolve_targets(rest, [target | acc])
      :error -> {:error, :invalid_command_arguments}
    end
  end

  defp resolve_targets(_names, _acc), do: {:error, :invalid_command_arguments}
end
