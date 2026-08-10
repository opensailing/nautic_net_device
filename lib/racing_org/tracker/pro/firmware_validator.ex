defmodule RacingOrg.Tracker.Pro.FirmwareValidator do
  @moduledoc """
  Marks the running firmware VALID once the device has connected to the RacingOrg
  server correctly (the secure channel's authenticated session is live — see
  `RacingOrg.Tracker.Pro.SecureTransport.ChannelClient`).

  Nerves boots OTA firmware in a "validation-pending" state (`nerves_fw_validated`
  = 0); if nothing calls `Nerves.Runtime.validate_firmware/0`, U-Boot REVERTS to the
  previous partition on the next reboot. `nerves_hub_link` only *checks* the flag, it
  does not set it — so the application must. We deliberately gate validation on a
  successful RacingOrg connection, NOT merely on boot or NervesHub:

    * a good OTA reaches RacingOrg → validates itself → STICKS.
    * a bad OTA that cannot establish the RacingOrg session → never validates →
      AUTO-REVERTS on the next reboot → self-heals.

  Idempotent: once the firmware is valid, this is a cheap no-op, so it is safe to
  call on every (re)connect. Best-effort: a failure is logged and never raises (it
  must never take down the channel). On host/test (`Nerves.Runtime` absent) it is a
  no-op unless the runtime functions are injected.
  """

  require Logger

  @doc """
  Validate the running firmware if it is not already valid. Returns
  `:already_valid | :validated | :unavailable | :error`.

  Injectable for tests:
    * `:firmware_valid?` — 0-arity, true if the firmware is already validated
      (default: `Nerves.Runtime.firmware_valid?/0`)
    * `:validate` — 0-arity, marks the firmware valid
      (default: `Nerves.Runtime.validate_firmware/0`)
    * `:runtime_module` — module supplying both default calls
      (default: `Nerves.Runtime`)
  """
  @spec validate_on_connect(keyword()) :: :already_valid | :validated | :unavailable | :error
  def validate_on_connect(opts \\ []) do
    runtime_module = Keyword.get(opts, :runtime_module, Nerves.Runtime)
    valid_fun = Keyword.get(opts, :firmware_valid?)
    validate_fun = Keyword.get(opts, :validate)

    cond do
      not callable?(valid_fun, runtime_module, :firmware_valid?) ->
        :unavailable

      firmware_valid?(valid_fun, runtime_module) ->
        :already_valid

      not callable?(validate_fun, runtime_module, :validate_firmware) ->
        :unavailable

      true ->
        case (validate_fun || fn -> default_validate(runtime_module) end).() do
          :ok ->
            Logger.info("[FirmwareValidator] firmware validated after RacingOrg connect")
            :validated

          failure ->
            Logger.warning("[FirmwareValidator] validation failed (will retry on next connect): #{inspect(failure)}")

            :error
        end
    end
  rescue
    e ->
      Logger.warning("[FirmwareValidator] validation failed (will retry on next connect): #{inspect(e)}")
      :error
  end

  @doc false
  @spec validation_available?(keyword()) :: boolean()
  def validation_available?(opts \\ []) do
    runtime_module = Keyword.get(opts, :runtime_module, Nerves.Runtime)

    valid_fun = Keyword.get(opts, :firmware_valid?)
    validate_fun = Keyword.get(opts, :validate)

    callable?(valid_fun, runtime_module, :firmware_valid?) and
      (callable?(validate_fun, runtime_module, :validate_firmware) or
         firmware_valid?(valid_fun, runtime_module))
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp callable?(fun, _runtime_module, _function) when is_function(fun, 0), do: true

  defp callable?(nil, runtime_module, function) do
    Code.ensure_loaded?(runtime_module) and function_exported?(runtime_module, function, 0)
  end

  defp callable?(_invalid, _runtime_module, _function), do: false

  defp firmware_valid?(fun, _runtime_module) when is_function(fun, 0), do: fun.() == true
  defp firmware_valid?(nil, runtime_module), do: default_valid?(runtime_module) == true

  defp default_valid?(runtime_module), do: apply(runtime_module, :firmware_valid?, [])
  defp default_validate(runtime_module), do: apply(runtime_module, :validate_firmware, [])
end
