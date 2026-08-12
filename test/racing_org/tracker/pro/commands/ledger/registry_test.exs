defmodule RacingOrg.Tracker.Pro.Commands.Ledger.RegistryTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands.Ledger.Registry
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical

  @max_result Contract.max_command_result_size()

  test "the supported command registry is closed and every type resolves to one provider" do
    assert Registry.command_types() == [
             :noop,
             :persist_checkpoints,
             :sync_checkpoints,
             :validate_firmware
           ]

    for type <- Registry.command_types() do
      assert {:ok, module} = Registry.provider(type)
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, :execute, 2)
      assert function_exported?(module, :recover, 2)
      assert function_exported?(module, :with_non_application_lease, 5)
    end

    assert {:error, :unsupported_command} = Registry.provider(:arbitrary)
    assert {:error, :unsupported_command} = Registry.provider("noop")
  end

  test "recovery verifiers cover exactly the supported types" do
    verifiers = Registry.recovery_verifiers()

    assert Map.keys(verifiers) |> Enum.sort() == Registry.command_types()

    for {type, {module, _context}} <- verifiers do
      assert {:ok, ^module} = Registry.provider(type)
    end
  end

  describe "decode_payload/1" do
    test "accepts exactly the canonical command envelope" do
      assert {:ok, decoded} = Registry.decode_payload(payload("noop", %{}))
      assert decoded == %{type: :noop, args: %{}}

      assert {:ok, decoded} =
               Registry.decode_payload(payload("persist_checkpoints", %{"targets" => ["polar"]}))

      assert decoded == %{type: :persist_checkpoints, args: %{targets: [:polar]}}
    end

    test "rejects noncanonical, unknown, and malformed envelopes without raising" do
      rows = [
        <<>>,
        <<0xFF>>,
        payload_bytes(%{"type" => "noop"}),
        payload_bytes(%{"type" => "noop", "args" => %{}, "extra" => 1}),
        payload_bytes(%{"type" => "not_a_command", "args" => %{}}),
        payload_bytes(%{"type" => 1, "args" => %{}}),
        payload_bytes(%{"type" => "noop", "args" => []}),
        payload_bytes(%{"type" => "noop", "args" => %{"unexpected" => true}}),
        payload_bytes(%{"type" => "persist_checkpoints", "args" => %{"targets" => []}}),
        payload_bytes(%{"type" => "persist_checkpoints", "args" => %{"targets" => ["nope"]}}),
        payload_bytes(%{"type" => "persist_checkpoints", "args" => %{"targets" => ["polar", "polar"]}}),
        payload_bytes(%{"type" => "validate_firmware", "args" => %{"targets" => ["polar"]}}),
        payload("noop", %{}) <> <<0>>
      ]

      for bytes <- rows do
        assert {:error, _reason} = Registry.decode_payload(bytes),
               "expected rejection for #{inspect(bytes, limit: 12)}"
      end
    end

    test "atom command types can never be created from untrusted payload text" do
      unknown = "definitely_not_an_existing_atom_#{System.unique_integer([:positive])}"
      assert {:error, :unsupported_command} = Registry.decode_payload(payload(unknown, %{}))
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  describe "resolve_type/1" do
    test "reserves a bounded result budget that always covers the encoded result" do
      for type <- Registry.command_types() do
        decoded = %{type: type, args: default_args(type)}
        assert {:ok, ^type, reserved} = Registry.resolve_type(decoded)
        assert is_integer(reserved) and reserved > 0 and reserved <= @max_result
      end
    end

    test "rejects anything outside the closed registry" do
      assert {:error, :unsupported_command} = Registry.resolve_type(%{type: :arbitrary, args: %{}})
      assert {:error, :unsupported_command} = Registry.resolve_type(%{})
      assert {:error, :unsupported_command} = Registry.resolve_type(:noop)
    end
  end

  describe "encode_result/2" do
    test "encodes within the reservation and round-trips canonically" do
      for type <- Registry.command_types() do
        outcome = %{outcome: :applied, detail: [:polar, :wind_shift]}
        assert {:ok, bytes} = Registry.encode_result(type, outcome)
        assert {:ok, _value} = Canonical.decode(bytes)

        assert {:ok, ^type, reserved} = Registry.resolve_type(%{type: type, args: default_args(type)})
        assert byte_size(bytes) <= reserved
      end
    end

    test "refuses results that would exceed the reservation" do
      oversized = %{outcome: :applied, detail: Enum.map(1..64, fn _ -> :polar end)}
      assert {:error, :command_result_reservation_exceeded} = Registry.encode_result(:noop, oversized)
    end
  end

  defp default_args(:persist_checkpoints), do: %{targets: [:polar]}
  defp default_args(:sync_checkpoints), do: %{targets: [:polar]}
  defp default_args(_type), do: %{}

  defp payload(type, args), do: payload_bytes(%{"type" => type, "args" => args})

  defp payload_bytes(value) do
    {:ok, bytes} = Canonical.encode(value)
    bytes
  end
end
