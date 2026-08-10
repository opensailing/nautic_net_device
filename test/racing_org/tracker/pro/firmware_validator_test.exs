defmodule RacingOrg.Tracker.Pro.FirmwareValidatorTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.FirmwareValidator

  test "validates when the firmware is not yet valid and validation returns exactly :ok" do
    parent = self()

    assert :validated =
             FirmwareValidator.validate_on_connect(
               firmware_valid?: fn -> false end,
               validate: fn ->
                 send(parent, :validated)
                 :ok
               end
             )

    assert_received :validated
  end

  test "does not treat another validation return as success and remains retryable" do
    parent = self()

    opts = [
      firmware_valid?: fn -> false end,
      validate: fn -> send(parent, :validation_attempted) end
    ]

    assert :error = FirmwareValidator.validate_on_connect(opts)
    assert :error = FirmwareValidator.validate_on_connect(opts)
    assert_received :validation_attempted
    assert_received :validation_attempted
  end

  test "returns :error when validation returns {:error, reason}" do
    assert :error =
             FirmwareValidator.validate_on_connect(
               firmware_valid?: fn -> false end,
               validate: fn -> {:error, :write_failed} end
             )
  end

  test "no-op (does not re-validate) when already valid" do
    assert :already_valid =
             FirmwareValidator.validate_on_connect(
               firmware_valid?: fn -> true end,
               validate: fn -> raise "must not be called" end
             )
  end

  test "best-effort: a failure is caught and returns :error (never raises)" do
    assert :error =
             FirmwareValidator.validate_on_connect(
               firmware_valid?: fn -> false end,
               validate: fn -> raise "no nerves runtime" end
             )
  end

  test "uses an injectable runtime module for the default validation path" do
    assert :validated = FirmwareValidator.validate_on_connect(runtime_module: __MODULE__.RuntimeModule)
  end

  test "no-op on host where Nerves.Runtime is unavailable and nothing injected" do
    assert :unavailable = FirmwareValidator.validate_on_connect()
  end

  defmodule RuntimeModule do
    def firmware_valid?, do: false
    def validate_firmware, do: :ok
  end
end
