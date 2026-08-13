defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.ValidateFirmware do
  @moduledoc """
  Read-only recovery provider for retired `validate_firmware` command intents.

  Firmware validation is owned exclusively by the supervised
  `RacingOrg.Tracker.Pro.FirmwareValidation.Trial` health gate. New command
  deliveries are not registered, and `execute/2` fails closed so this provider
  cannot bypass the trial and invoke the irreversible validation writer.

  Existing pending intents may still be present in durable ledgers. Recovery
  never runs the effect; it reads the firmware's own validation flag, which is the
  authoritative record of whether the old effect landed:

    * already valid -> `:ambiguous`. The flag cannot prove whether the retired
      command performed validation or the supervised trial did, so recovery does
      not fabricate an applied result or ACK.
    * not valid -> `{:not_applied, :effect_verified_absent}`. The old command's
      effect provably did not land, so the intent is rejected under the lease.
    * flag unreadable -> `:ambiguous`. The intent stays pending and no ACK is
      emitted rather than guessing about an irreversible effect.
  """

  use RacingOrg.Tracker.Pro.Commands.Ledger.Provider

  @impl true
  def execute(_intent, _context), do: {:error, :firmware_validation_requires_supervised_trial}

  @impl true
  def recover(_intent, context) do
    case firmware_valid?(context) do
      {:ok, false} -> {:not_applied, :effect_verified_absent}
      {:ok, true} -> :ambiguous
      :error -> :ambiguous
    end
  end

  defp firmware_valid?(context) do
    opts = validator_opts(context)

    if valid_flag_readable?(opts) do
      {:ok, read_valid_flag(opts) == true}
    else
      :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp valid_flag_readable?(opts) do
    case Keyword.get(opts, :firmware_valid?) do
      fun when is_function(fun, 0) ->
        true

      nil ->
        runtime_module = Keyword.get(opts, :runtime_module, Nerves.Runtime)
        Code.ensure_loaded?(runtime_module) and function_exported?(runtime_module, :firmware_valid?, 0)

      _invalid ->
        false
    end
  end

  defp read_valid_flag(opts) do
    case Keyword.get(opts, :firmware_valid?) do
      fun when is_function(fun, 0) -> fun.()
      _default -> apply(Keyword.get(opts, :runtime_module, Nerves.Runtime), :firmware_valid?, [])
    end
  end

  defp validator_opts(context) when is_list(context), do: context
  defp validator_opts(%{validator_opts: opts}) when is_list(opts), do: opts
  defp validator_opts(_context), do: []
end
