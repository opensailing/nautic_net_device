defmodule RacingOrg.Tracker.Pro.HardwareIdentityTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.HardwareIdentity

  test "defines the provider and identifier callbacks" do
    callbacks = HardwareIdentity.behaviour_info(:callbacks)

    assert {:provider, 0} in callbacks
    assert {:identifier, 0} in callbacks
  end
end
