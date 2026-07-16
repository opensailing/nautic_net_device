defmodule RacingOrg.Tracker.Pro.NmeaIdentity do
  @moduledoc """
  The per-sensor canonical NMEA identity: NMEA NAME → the backend's uppercase-hex
  hardware-id form.

  An NMEA 2000 sensor's stable identity is its 64-bit NAME, but that NAME reaches
  the device in several shapes: the raw 8-byte binary observed on the bus, the
  unsigned integer it decodes to, or a hex string the backend derived from the same
  NAME during DataSet ingest (with or without a `0x` prefix, any case). For a
  backend-selected sensor to match a live on-bus one, BOTH sides must be reduced to
  a single canonical form before comparison — the backend's uppercase-hex string.

  `canonical_hardware_id/1` performs that reduction. It was extracted UNCHANGED
  from `RacingOrg.Tracker.Pro.ClockSource.Config`'s private source matching so the
  clock-source policy and the calibration layer share one identity definition.
  """

  alias RacingOrg.Tracker.Pro.DeviceInfo

  @doc """
  Canonicalize an NMEA NAME identity — the observed name from the bus OR a
  configured identifier — into the backend's uppercase-hex hardware-id form, so
  both sides compare equal:

    * `nil` -> `nil`
    * a non-negative integer NMEA NAME -> uppercase hex
    * a printable hex string (optional `0x`/`0X` prefix) -> trimmed, unprefixed,
      UPPERCASE (the configured-identifier case, e.g. `"0x1a2b"` -> `"1A2B"`)
    * an 8-byte binary NMEA NAME -> unsigned 64-bit integer -> uppercase hex
      (the observed on-bus case; reuses `DeviceInfo.hw_id/1`)
    * any other binary (not hex, not 8 bytes) -> its original string, so literal
      label-style names still match and invalid text never crashes matching
    * anything else -> `to_string/1`

  The printable-hex check runs BEFORE the 8-byte-binary check, so an 8-character
  hex string (e.g. `"aabbccdd"`) canonicalizes as hex TEXT, not as raw NAME bytes.
  """
  @spec canonical_hardware_id(term()) :: String.t() | nil
  def canonical_hardware_id(nil), do: nil

  def canonical_hardware_id(name) when is_integer(name) and name >= 0, do: integer_to_hex(name)

  def canonical_hardware_id(name) when is_binary(name) do
    case printable_hex(name) do
      nil -> if byte_size(name) == 8, do: name |> DeviceInfo.hw_id() |> integer_to_hex(), else: name
      hex -> hex
    end
  end

  def canonical_hardware_id(name), do: to_string(name)

  # The uppercase-hex form of `name` if it is a printable hex string (optional
  # `0x`/`0X` prefix), else `nil`. Guarded on `String.printable?/1` so it is safe to
  # call on a raw (non-UTF-8) NAME binary.
  defp printable_hex(name) do
    if String.printable?(name) do
      candidate = name |> String.trim() |> strip_hex_prefix()
      if hex_string?(candidate), do: String.upcase(candidate)
    end
  end

  defp integer_to_hex(i) when is_integer(i) and i >= 0, do: i |> Integer.to_string(16) |> String.upcase()

  defp strip_hex_prefix("0x" <> rest), do: rest
  defp strip_hex_prefix("0X" <> rest), do: rest
  defp strip_hex_prefix(other), do: other

  defp hex_string?(""), do: false
  defp hex_string?(s) when is_binary(s), do: match?({_int, ""}, Integer.parse(s, 16))
end
