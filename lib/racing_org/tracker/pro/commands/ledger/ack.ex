defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Ack do
  @moduledoc false

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Command
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages

  @fence_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :required_generation,
    :required_manifest_hash,
    :command_epoch,
    :command_sequence,
    :command_id
  ]

  @spec build(map(), :applied | :duplicate | :rejected, atom(), binary()) ::
          {:ok, map()} | {:error, term()}
  def build(command, status, reason, result) when is_map(command) do
    with {:ok, command_hash} <- Map.fetch(command, :command_hash),
         {:ok, result_hash} <- Command.result_hash(%{status: status, reason: reason, result: result}) do
      ack =
        command
        |> Map.take(@fence_keys)
        |> Map.merge(%{
          command_hash: command_hash,
          status: status,
          reason: reason,
          result_hash: result_hash,
          result: result
        })

      case Messages.encode(:command_ack, ack) do
        {:ok, _bytes} -> {:ok, ack}
        {:error, _reason} = error -> error
      end
    else
      :error -> {:error, :invalid_command_ack_source}
      {:error, _reason} = error -> error
    end
  end

  def build(_command, _status, _reason, _result), do: {:error, :invalid_command_ack_source}
end
