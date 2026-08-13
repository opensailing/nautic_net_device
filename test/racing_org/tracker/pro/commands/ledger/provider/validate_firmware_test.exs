defmodule RacingOrg.Tracker.Pro.Commands.Ledger.Provider.ValidateFirmwareTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Provider.ValidateFirmware

  defmodule ReadOnlyInvalidFirmwareRuntime do
    def firmware_valid?, do: false
  end

  defmodule ReadOnlyValidFirmwareRuntime do
    def firmware_valid?, do: true
  end

  test "execute fails closed without invoking a firmware validation writer" do
    parent = self()

    assert {:error, :firmware_validation_requires_supervised_trial} =
             ValidateFirmware.execute(%{},
               validate_fun: fn -> send(parent, :firmware_validated) end,
               firmware_valid?: fn -> false end
             )

    refute_received :firmware_validated
  end

  test "recovery proves absence from a readable false flag without a validation writer" do
    assert {:not_applied, :effect_verified_absent} =
             ValidateFirmware.recover(%{},
               runtime_module: ReadOnlyInvalidFirmwareRuntime
             )
  end

  test "recovery does not fabricate application from an already-valid flag" do
    assert :ambiguous =
             ValidateFirmware.recover(%{},
               runtime_module: ReadOnlyValidFirmwareRuntime
             )
  end

  test "recovery stays ambiguous when non-application cannot be proven" do
    assert :ambiguous = ValidateFirmware.recover(%{}, [])
  end
end
