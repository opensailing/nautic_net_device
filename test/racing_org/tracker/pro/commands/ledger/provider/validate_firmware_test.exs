defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.ValidateFirmwareTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Provider.ValidateFirmware

  defmodule ReadOnlyInvalidFirmwareRuntime do
    def firmware_valid?, do: false
  end

  test "recovery proves absence from a readable false flag without a validation writer" do
    assert {:not_applied, :effect_verified_absent} =
             ValidateFirmware.recover(%{},
               runtime_module: ReadOnlyInvalidFirmwareRuntime
             )
  end
end
