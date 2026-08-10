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
  """
  @spec validate_on_connect(keyword()) :: :already_valid | :validated | :unavailable | :error
  def validate_on_connect(opts \\ []) do
    valid_fun = Keyword.get(opts, :firmware_valid?)
    validate_fun = Keyword.get(opts, :validate)

    cond do
      is_nil(valid_fun) and is_nil(validate_fun) and not runtime_available?() ->
        :unavailable

      (valid_fun || (&default_valid?/0)).() ->
        :already_valid

      true ->
        case (validate_fun || (&default_validate/0)).() do
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

  defp runtime_available?, do: Code.ensure_loaded?(Nerves.Runtime)

  defp default_valid?, do: apply(Nerves.Runtime, :firmware_valid?, [])
  defp default_validate, do: apply(Nerves.Runtime, :validate_firmware, [])
end
