defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Section do
  @moduledoc """
  Pure section construction, secret-descriptor framing, tombstones, and hashing.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical

  @hash_size 32
  @secret_ref_size 16
  @u32_max 0xFFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @wifi_content_fields MapSet.new(["enabled", "ssid", "version"])
  @wifi_plaintext_secret_fields MapSet.new(["password", "passphrase", "psk", "wifi_psk"])

  @doc "Build one present section from a canonical top-level map."
  def build(name, content, opts \\ [])

  def build(name, content, opts) when is_list(opts) do
    secrets = Keyword.get(opts, :secrets, [])

    with {:ok, code, schema_version} <- section_identity(name),
         true <- is_map(content) || {:error, :section_content_must_be_map},
         :ok <- validate_section_content(name, content),
         {:ok, canonical_content} <- Canonical.encode(content),
         {:ok, secrets} <- validate_secrets(name, secrets),
         section = %{
           name: name,
           code: code,
           schema_version: schema_version,
           tombstone: false,
           content: canonical_content,
           content_length: byte_size(canonical_content),
           secrets: secrets,
           hash: nil
         },
         {:ok, preimage} <- preimage(section) do
      {:ok, %{section | hash: :crypto.hash(:sha256, preimage)}}
    else
      false -> {:error, :section_content_must_be_map}
      {:error, _reason} = error -> error
    end
  end

  def build(_name, _content, _opts), do: {:error, :invalid_section}

  @doc "Build an explicit, domain-separated tombstone for a tombstoneable section."
  def tombstone(name) do
    with {:ok, code, schema_version} <- section_identity(name),
         true <- Contract.tombstone_allowed?(name) || {:error, :tombstone_not_allowed},
         section = %{
           name: name,
           code: code,
           schema_version: schema_version,
           tombstone: true,
           content: <<>>,
           content_length: 0,
           secrets: [],
           hash: nil
         },
         {:ok, preimage} <- preimage(section) do
      {:ok, %{section | hash: :crypto.hash(:sha256, preimage)}}
    else
      false -> {:error, :tombstone_not_allowed}
      {:error, _reason} = error -> error
    end
  end

  @doc "Drop canonical content while retaining the complete manifest descriptor."
  def descriptor(section) when is_map(section) do
    Map.take(section, [
      :name,
      :code,
      :schema_version,
      :tombstone,
      :content_length,
      :secrets,
      :hash
    ])
  end

  @doc "Return the exact section-hash preimage for a built section."
  def preimage(%{content: content} = section) when is_binary(content) do
    preimage(section, content)
  end

  def preimage(_), do: {:error, :invalid_section}

  @doc "Verify canonical bytes against a section descriptor and its domain-separated hash."
  def verify(section, content) when is_map(section) and is_binary(content) do
    with :ok <- validate_descriptor(section),
         :ok <- validate_content_shape(section, content),
         {:ok, preimage} <- preimage(section, content),
         computed = :crypto.hash(:sha256, preimage),
         true <- secure_equal(computed, section.hash) || {:error, :section_hash_mismatch} do
      {:ok, Map.put(section, :content, content)}
    else
      false -> {:error, :section_hash_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def verify(_section, _content), do: {:error, :invalid_section}

  @doc "Encode one complete manifest section descriptor."
  def encode_descriptor(section) when is_map(section) do
    with :ok <- validate_descriptor(section),
         {:ok, secrets} <- encode_secret_descriptors(section.secrets),
         tombstone <- if(section.tombstone, do: 1, else: 0) do
      {:ok,
       <<section.code, section.schema_version::16, tombstone, section.content_length::64, length(section.secrets)>> <>
         secrets <> section.hash}
    end
  end

  def encode_descriptor(_), do: {:error, :invalid_section}

  @doc "Decode one descriptor and return the unconsumed tail."
  def take_descriptor(<<code, schema_version::16, tombstone_code, content_length::64, secret_count, rest::binary>>) do
    with {:ok, name} <- known_section_name(code),
         :ok <- validate_schema(name, schema_version),
         {:ok, tombstone} <- decode_tombstone(tombstone_code),
         {:ok, secrets, rest} <- take_secret_descriptors(rest, secret_count, []),
         <<hash::binary-size(@hash_size), trailing::binary>> <- rest,
         descriptor = %{
           name: name,
           code: code,
           schema_version: schema_version,
           tombstone: tombstone,
           content_length: content_length,
           secrets: secrets,
           hash: hash
         },
         :ok <- validate_descriptor(descriptor) do
      {:ok, descriptor, trailing}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  def take_descriptor(_), do: {:error, :truncated}

  @doc "Encode the frozen Wi-Fi secret reference and keyed digest descriptor."
  def encode_secret_descriptor(descriptor) when is_map(descriptor) do
    with {:ok, descriptor} <- validate_secret_descriptor(descriptor),
         {:ok, kind_code} <- Contract.secret_kind(descriptor.kind) do
      {:ok,
       <<kind_code, descriptor.digest_key_id::32, descriptor.ref::binary-size(@secret_ref_size),
         descriptor.digest::binary-size(@hash_size)>>}
    end
  end

  def encode_secret_descriptor(_), do: {:error, :invalid_secret_descriptor}

  @doc "Decode one secret descriptor and return the unconsumed tail."
  def take_secret_descriptor(
        <<kind_code, digest_key_id::32, ref::binary-size(@secret_ref_size), digest::binary-size(@hash_size),
          rest::binary>>
      ) do
    with {:ok, kind} <- Contract.secret_kind(kind_code),
         {:ok, descriptor} <-
           validate_secret_descriptor(%{
             kind: kind,
             digest_key_id: digest_key_id,
             ref: ref,
             digest: digest
           }) do
      {:ok, descriptor, rest}
    end
  end

  def take_secret_descriptor(_), do: {:error, :truncated}

  defp preimage(section, content) do
    with :ok <- validate_descriptor(Map.put(section, :content_length, byte_size(content)), false),
         {:ok, secrets} <- encode_secret_descriptors(section.secrets) do
      name = Atom.to_string(section.name)
      tombstone = if(section.tombstone, do: 1, else: 0)

      {:ok,
       Contract.section_domain() <>
         <<Contract.version(), byte_size(name)::16, name::binary, section.schema_version::16, tombstone,
           byte_size(content)::64, length(section.secrets)>> <>
         secrets <> content}
    end
  end

  defp validate_descriptor(section, require_hash? \\ true) do
    with {:ok, code, expected_schema} <- section_identity(Map.get(section, :name)),
         true <- Map.get(section, :code) == code || {:error, :section_code_mismatch},
         true <-
           Map.get(section, :schema_version) == expected_schema ||
             {:error, :unsupported_section_schema},
         true <- is_boolean(Map.get(section, :tombstone)) || {:error, :invalid_tombstone},
         true <-
           (not Map.get(section, :tombstone) or Contract.tombstone_allowed?(section.name)) ||
             {:error, :tombstone_not_allowed},
         content_length <- Map.get(section, :content_length),
         true <-
           (is_integer(content_length) and content_length >= 0 and content_length <= @u64_max) ||
             {:error, :invalid_content_length},
         true <-
           (Map.get(section, :tombstone) or content_length > 0) ||
             {:error, :invalid_content_length},
         true <- content_length <= Contract.max_section_size() || {:error, :section_too_large},
         {:ok, secrets} <- validate_secrets(section.name, Map.get(section, :secrets)),
         true <- secrets == Map.get(section, :secrets) || {:error, :secrets_out_of_order},
         :ok <- validate_hash(section, require_hash?),
         :ok <- validate_tombstone_shape(section, secrets) do
      :ok
    else
      false -> {:error, :invalid_section}
      {:error, _reason} = error -> error
    end
  end

  defp validate_hash(_section, false), do: :ok

  defp validate_hash(section, true) do
    cond do
      not valid_hash?(Map.get(section, :hash)) ->
        {:error, :invalid_section_hash}

      Map.get(section, :tombstone) ->
        with {:ok, preimage} <- preimage(section, <<>>),
             computed = :crypto.hash(:sha256, preimage),
             true <- secure_equal(computed, section.hash) || {:error, :section_hash_mismatch} do
          :ok
        else
          false -> {:error, :section_hash_mismatch}
          {:error, _reason} = error -> error
        end

      true ->
        :ok
    end
  end

  defp validate_content_shape(%{tombstone: true, content_length: 0, secrets: []}, <<>>), do: :ok

  defp validate_content_shape(%{tombstone: true}, _content), do: {:error, :invalid_tombstone_shape}

  defp validate_content_shape(%{name: name, content_length: expected}, content)
       when byte_size(content) == expected do
    with {:ok, decoded} <- Canonical.decode(content),
         true <- is_map(decoded) || {:error, :section_content_must_be_map},
         :ok <- validate_section_content(name, decoded) do
      :ok
    else
      false -> {:error, :section_content_must_be_map}
      {:error, _reason} = error -> error
    end
  end

  defp validate_content_shape(_section, _content), do: {:error, :section_length_mismatch}

  defp validate_tombstone_shape(%{tombstone: true, content_length: 0}, []), do: :ok
  defp validate_tombstone_shape(%{tombstone: true}, _secrets), do: {:error, :invalid_tombstone_shape}
  defp validate_tombstone_shape(%{tombstone: false}, _secrets), do: :ok

  defp validate_section_content(:wifi, content) do
    Enum.reduce_while(content, :ok, fn {key, value}, :ok ->
      with {:ok, field} <- normalize_wifi_field(key),
           :ok <- validate_wifi_field(field),
           :ok <- validate_wifi_value(field, value) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_section_content(_name, _content), do: :ok

  defp normalize_wifi_field(field) when is_atom(field),
    do: field |> Atom.to_string() |> normalize_wifi_field()

  defp normalize_wifi_field(field) when is_binary(field) do
    if String.valid?(field) do
      {:ok, String.normalize(field, :nfc)}
    else
      {:error, :invalid_wifi_content}
    end
  end

  defp normalize_wifi_field(_field), do: {:error, :invalid_wifi_content}

  defp validate_wifi_field(field) do
    cond do
      MapSet.member?(@wifi_plaintext_secret_fields, String.downcase(field)) ->
        {:error, :plaintext_wifi_secret_forbidden}

      MapSet.member?(@wifi_content_fields, field) ->
        :ok

      true ->
        {:error, :unknown_wifi_field}
    end
  end

  defp validate_wifi_value("enabled", value) when is_boolean(value), do: :ok

  defp validate_wifi_value("version", value)
       when is_integer(value) and value >= 0 and value <= @u64_max,
       do: :ok

  defp validate_wifi_value("ssid", nil), do: :ok

  defp validate_wifi_value("ssid", value) when is_binary(value) do
    if String.valid?(value) and String.normalize(value, :nfc) == value and byte_size(value) <= 32,
      do: :ok,
      else: {:error, :invalid_wifi_content}
  end

  defp validate_wifi_value(_field, _value), do: {:error, :invalid_wifi_content}

  defp validate_secrets(name, secrets) when is_list(secrets) do
    cond do
      name != :wifi and secrets != [] ->
        {:error, :secret_not_allowed}

      length(secrets) > 1 ->
        if duplicate_secret_input?(secrets) do
          {:error, :duplicate_secret_descriptor}
        else
          {:error, :too_many_secret_descriptors}
        end

      true ->
        secrets
        |> Enum.reduce_while({:ok, []}, fn descriptor, {:ok, acc} ->
          case validate_secret_descriptor(descriptor) do
            {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, descriptors} ->
            sorted = Enum.sort_by(descriptors, &secret_sort_key/1)

            if duplicate_secret_input?(sorted) do
              {:error, :duplicate_secret_descriptor}
            else
              {:ok, sorted}
            end

          error ->
            error
        end
    end
  end

  defp validate_secrets(_name, _secrets), do: {:error, :invalid_secret_descriptors}

  defp validate_secret_descriptor(descriptor) do
    expected_keys = [:kind, :digest_key_id, :ref, :digest]

    cond do
      not is_map(descriptor) ->
        {:error, :invalid_secret_descriptor}

      Enum.sort(Map.keys(descriptor)) != Enum.sort(expected_keys) ->
        {:error, :invalid_secret_descriptor}

      Contract.secret_kind(descriptor.kind) == {:error, :unknown_secret_kind} ->
        {:error, :unknown_secret_kind}

      not is_integer(descriptor.digest_key_id) or descriptor.digest_key_id < 0 or
          descriptor.digest_key_id > @u32_max ->
        {:error, :invalid_digest_key_id}

      not is_binary(descriptor.ref) or byte_size(descriptor.ref) != @secret_ref_size or
          descriptor.ref == :binary.copy(<<0>>, @secret_ref_size) ->
        {:error, :invalid_secret_reference}

      not valid_hash?(descriptor.digest) ->
        {:error, :invalid_secret_digest}

      true ->
        {:ok, descriptor}
    end
  end

  defp encode_secret_descriptors(secrets) do
    secrets
    |> Enum.reduce_while({:ok, []}, fn descriptor, {:ok, acc} ->
      case encode_secret_descriptor(descriptor) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, encoded |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp take_secret_descriptors(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_secret_descriptors(rest, count, acc) do
    with {:ok, descriptor, trailing} <- take_secret_descriptor(rest) do
      take_secret_descriptors(trailing, count - 1, [descriptor | acc])
    end
  end

  defp section_identity(name) do
    case Contract.section_code(name) do
      code when is_integer(code) -> {:ok, code, Contract.section_schema_version(name)}
      {:error, _reason} = error -> error
    end
  end

  defp known_section_name(code) do
    case Contract.section_name(code) do
      name when is_atom(name) -> {:ok, name}
      {:error, _reason} = error -> error
    end
  end

  defp validate_schema(name, schema_version) do
    if Contract.section_schema_version(name) == schema_version do
      :ok
    else
      {:error, :unsupported_section_schema}
    end
  end

  defp decode_tombstone(0), do: {:ok, false}
  defp decode_tombstone(1), do: {:ok, true}
  defp decode_tombstone(_), do: {:error, :invalid_tombstone}

  defp duplicate_secret_input?([left, right | rest]) do
    secret_sort_key(left) == secret_sort_key(right) or duplicate_secret_input?([right | rest])
  end

  defp duplicate_secret_input?(_), do: false

  defp secret_sort_key(descriptor) when is_map(descriptor) do
    {Map.get(descriptor, :kind), Map.get(descriptor, :digest_key_id), Map.get(descriptor, :ref)}
  end

  defp secret_sort_key(_), do: {nil, nil, nil}

  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == @hash_size

  defp secure_equal(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal(_, _), do: false
end
