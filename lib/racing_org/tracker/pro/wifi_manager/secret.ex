defmodule RacingOrg.Tracker.Pro.WiFiManager.Secret do
  @moduledoc """
  A short-lived Wi-Fi credential whose normal inspection is always redacted.

  The wrapper may cross a `WiFiManager` call boundary, but it is never retained in
  manager state or written to a Desired State generation artifact.
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @opaque t :: %__MODULE__{bytes: binary()}

  @spec new(binary()) :: t()
  def new(bytes) when is_binary(bytes), do: %__MODULE__{bytes: bytes}

  @doc false
  @spec unwrap(t()) :: binary()
  def unwrap(%__MODULE__{bytes: bytes}), do: bytes

  @doc false
  @spec redact(term()) :: term()
  def redact(%__MODULE__{}), do: :redacted
  def redact(%_struct{} = value), do: value

  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if secret_key?(key), do: {key, :redacted}, else: {key, redact(value)}
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  def redact(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()
  end

  def redact(value), do: value

  defp secret_key?(key) when is_atom(key), do: key |> Atom.to_string() |> secret_key?()

  defp secret_key?(key) when is_binary(key) do
    String.downcase(key) in ["psk", "wifi_psk", "password", "passphrase"]
  rescue
    _error -> false
  end

  defp secret_key?(_key), do: false
end

defimpl Inspect, for: RacingOrg.Tracker.Pro.WiFiManager.Secret do
  import Inspect.Algebra

  def inspect(_secret, opts) do
    concat(["#", to_doc(RacingOrg.Tracker.Pro.WiFiManager.Secret, opts), "<REDACTED>"])
  end
end
