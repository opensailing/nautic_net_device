defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Secret do
  @moduledoc """
  Server-keyed desired-state secret digest construction.

  The key is deliberately external to Cloak, recovery identifiers, and secure-session
  material. Only the resulting key id, reference, and HMAC belong in a generation.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @device_id_size 16
  @secret_ref_size 16
  @u32_max 0xFFFF_FFFF
  @max_secret_size 1_024

  @doc "Compute the domain-separated HMAC-SHA256 secret digest."
  def digest(key, attrs, secret) do
    with {:ok, preimage} <- preimage(key, attrs, secret) do
      {:ok, :crypto.mac(:hmac, :sha256, key, preimage)}
    end
  end

  @doc "Compute the digest or raise for trusted construction code."
  def digest!(key, attrs, secret) do
    case digest(key, attrs, secret) do
      {:ok, digest} -> digest
      {:error, reason} -> raise ArgumentError, "invalid desired-state secret digest: #{inspect(reason)}"
    end
  end

  defp preimage(key, attrs, secret) do
    with :ok <- validate_key(key),
         :ok <- validate_attrs(attrs),
         :ok <- validate_secret(secret),
         {:ok, section_code} <- section_code(attrs.section),
         {:ok, kind_code} <- Contract.secret_kind(attrs.secret_kind),
         true <- section_code == Contract.section_code(:wifi) || {:error, :secret_not_allowed} do
      section_name = Atom.to_string(attrs.section)

      {:ok,
       Contract.secret_digest_domain() <>
         <<Contract.version(), attrs.device_id::binary-size(@device_id_size), byte_size(section_name)::16,
           section_name::binary, attrs.section_schema_version::16, kind_code, attrs.digest_key_id::32,
           attrs.secret_ref::binary-size(@secret_ref_size), byte_size(secret)::16, secret::binary>>}
    else
      false -> {:error, :secret_not_allowed}
      {:error, _reason} = error -> error
    end
  end

  defp validate_key(key) when is_binary(key) and byte_size(key) >= 32, do: :ok
  defp validate_key(_), do: {:error, :digest_key_too_short}

  defp validate_attrs(attrs) when is_map(attrs) do
    expected = [
      :device_id,
      :section,
      :section_schema_version,
      :secret_kind,
      :digest_key_id,
      :secret_ref
    ]

    cond do
      Enum.sort(Map.keys(attrs)) != Enum.sort(expected) ->
        {:error, :invalid_secret_digest_attrs}

      not is_binary(attrs.device_id) or byte_size(attrs.device_id) != @device_id_size ->
        {:error, :invalid_device_id}

      Contract.section_schema_version(attrs.section) != attrs.section_schema_version ->
        {:error, :unsupported_section_schema}

      Contract.secret_kind(attrs.secret_kind) == {:error, :unknown_secret_kind} ->
        {:error, :unknown_secret_kind}

      not is_integer(attrs.digest_key_id) or attrs.digest_key_id < 0 or
          attrs.digest_key_id > @u32_max ->
        {:error, :invalid_digest_key_id}

      not is_binary(attrs.secret_ref) or byte_size(attrs.secret_ref) != @secret_ref_size or
          attrs.secret_ref == :binary.copy(<<0>>, @secret_ref_size) ->
        {:error, :invalid_secret_reference}

      true ->
        :ok
    end
  end

  defp validate_attrs(_), do: {:error, :invalid_secret_digest_attrs}

  defp validate_secret(secret)
       when is_binary(secret) and byte_size(secret) <= @max_secret_size,
       do: :ok

  defp validate_secret(secret) when is_binary(secret), do: {:error, :secret_too_large}
  defp validate_secret(_), do: {:error, :invalid_secret}

  defp section_code(section) do
    case Contract.section_code(section) do
      code when is_integer(code) -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end
end
