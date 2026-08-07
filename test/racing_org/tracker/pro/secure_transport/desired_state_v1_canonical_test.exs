defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1CanonicalTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical

  describe "canonical scalar/map/list encoding" do
    test "encodes maps in normalized byte order and atoms as strings" do
      value = %{"b" => true, "kind" => :library, a: 1}

      assert {:ok, encoded} = Canonical.encode(value)

      assert Base.encode16(encoded, case: :lower) ==
               "09000000030001610300000000000000010001620200046b696e6407000000076c696272617279"

      assert {:ok, %{"a" => 1, "b" => true, "kind" => "library"}} =
               Canonical.decode(encoded)
    end

    test "encodes every scalar type without JSON ambiguity" do
      value = [
        nil,
        false,
        true,
        0,
        0xFFFF_FFFF_FFFF_FFFF,
        -1,
        -0x8000_0000_0000_0000,
        1.5,
        -0.0,
        Canonical.bytes(<<0x00, 0xFF>>),
        "Ångström"
      ]

      assert {:ok, encoded} = Canonical.encode(value)
      assert {:ok, decoded} = Canonical.decode(encoded)

      assert decoded == [
               nil,
               false,
               true,
               0,
               0xFFFF_FFFF_FFFF_FFFF,
               -1,
               -0x8000_0000_0000_0000,
               1.5,
               0.0,
               Canonical.bytes(<<0x00, 0xFF>>),
               "Ångström"
             ]

      assert <<0x05, 0::64>> = canonical_element(-0.0)
    end

    test "normalizes text and map keys to NFC before encoding" do
      decomposed = "é"

      assert {:ok, encoded} = Canonical.encode(%{decomposed => decomposed})
      assert {:ok, %{"é" => "é"}} = Canonical.decode(encoded)
    end

    test "rejects keys that collide after atom conversion or NFC normalization" do
      assert {:error, :duplicate_map_key} = Canonical.encode(%{:mode => 1, "mode" => 2})
      assert {:error, :duplicate_map_key} = Canonical.encode(%{"é" => 1, "é" => 2})
    end

    test "rejects invalid numbers, non-text binaries, invalid keys, and oversize values" do
      assert {:error, :integer_out_of_range} = Canonical.encode(0x1_0000_0000_0000_0000)
      assert {:error, :integer_out_of_range} = Canonical.encode(-0x8000_0000_0000_0001)
      assert {:error, :invalid_utf8} = Canonical.encode(<<0xFF>>)
      assert {:error, :invalid_map_key} = Canonical.encode(%{1 => "not a key"})
      assert {:error, :map_key_too_long} = Canonical.encode(%{String.duplicate("k", 129) => 1})
      assert {:error, :value_too_large} = Canonical.encode(Canonical.bytes(:binary.copy(<<0>>, 16_777_217)))
    end

    test "rejects excessive nesting and collection counts" do
      too_deep = Enum.reduce(1..17, nil, fn _, acc -> [acc] end)

      assert {:error, :max_depth_exceeded} = Canonical.encode(too_deep)
      assert {:error, :collection_too_large} = Canonical.encode(Enum.to_list(1..65_536))
    end
  end

  describe "strict decoding" do
    test "rejects unknown tags, truncation, trailing bytes, and noncanonical integers" do
      assert {:error, :unknown_type_tag} = Canonical.decode(<<0xFF>>)
      assert {:error, :non_finite_float} = Canonical.decode(<<0x05, 0x7FF0_0000_0000_0000::64>>)
      assert {:error, :non_finite_float} = Canonical.decode(<<0x05, 0x7FF8_0000_0000_0001::64>>)
      assert {:error, :truncated} = Canonical.decode(<<0x03, 1, 2>>)
      assert {:error, :trailing_bytes} = Canonical.decode(<<0x00, 0x00>>)
      assert {:error, :noncanonical_negative_integer} = Canonical.decode(<<0x04, 0::signed-big-64>>)
    end

    test "rejects non-NFC strings, negative zero, duplicate keys, and out-of-order keys" do
      decomposed = "é"

      non_nfc = <<0x07, byte_size(decomposed)::32, decomposed::binary>>
      negative_zero = <<0x05, 0x8000_0000_0000_0000::64>>

      duplicate_keys =
        <<0x09, 2::32, 1::16, "a", 0x00, 1::16, "a", 0x00>>

      out_of_order =
        <<0x09, 2::32, 1::16, "b", 0x00, 1::16, "a", 0x00>>

      assert {:error, :noncanonical_unicode} = Canonical.decode(non_nfc)
      assert {:error, :negative_zero} = Canonical.decode(negative_zero)
      assert {:error, :duplicate_map_key} = Canonical.decode(duplicate_keys)
      assert {:error, :map_keys_out_of_order} = Canonical.decode(out_of_order)
    end
  end

  describe "schema field validation" do
    test "rejects missing and unknown fields after key normalization" do
      assert :ok = Canonical.validate_fields(%{"a" => 1, b: 2}, ["a"], ["b"])
      assert {:error, {:missing_fields, ["a"]}} = Canonical.validate_fields(%{}, ["a"], [])
      assert {:error, {:unknown_fields, ["c"]}} = Canonical.validate_fields(%{"a" => 1, "c" => 2}, ["a"], [])
    end
  end

  defp canonical_element(value) do
    assert {:ok, <<0x08, 1::32, element::binary>>} = Canonical.encode([value])
    element
  end
end
