defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Manifest do
  @moduledoc """
  Strict complete-generation manifest encoding and complete-hash verification.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Section

  @device_id_size 16
  @hash_size 32
  @u32_max 0xFFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @max_firmware_size 80
  @attrs [:device_id, :credential_epoch, :generation, :minimum_firmware, :required_capabilities, :sections]

  @doc "Encode one complete immutable manifest and append its domain-separated complete hash."
  def encode(attrs) when is_map(attrs) do
    with :ok <- exact_keys(attrs, @attrs),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <- positive_u64(attrs.generation, :invalid_generation),
         {:ok, firmware} <- encode_firmware(attrs.minimum_firmware),
         {:ok, capabilities} <- encode_capabilities(attrs.required_capabilities),
         {:ok, sections} <- encode_sections(attrs.sections) do
      body =
        Contract.manifest_domain() <>
          <<Contract.version(), attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32,
            attrs.generation::64, Contract.desired_state_version()::16, Contract.section_set_version()::16>> <>
          firmware <>
          capabilities <>
          <<length(attrs.sections)::16>> <>
          sections

      complete_hash = :crypto.hash(:sha256, body)
      bytes = body <> <<@hash_size::16, complete_hash::binary>>

      if byte_size(bytes) <= Contract.max_manifest_size() do
        {:ok, bytes}
      else
        {:error, :manifest_too_large}
      end
    end
  end

  def encode(_), do: {:error, :invalid_manifest}

  @doc "Strictly decode, canonicalize, and verify a complete manifest."
  def decode(bytes) when is_binary(bytes) do
    cond do
      byte_size(bytes) > Contract.max_manifest_size() ->
        {:error, :manifest_too_large}

      true ->
        with {:ok, rest} <- strip_domain_version(bytes),
             <<device_id::binary-size(@device_id_size), credential_epoch::32, generation::64, desired_state_version::16,
               section_set_version::16, rest::binary>> <- rest,
             :ok <- ensure(generation > 0, :invalid_generation),
             :ok <-
               ensure(
                 desired_state_version == Contract.desired_state_version(),
                 :incompatible_desired_state_version
               ),
             :ok <-
               ensure(
                 section_set_version == Contract.section_set_version(),
                 :incompatible_section_set
               ),
             {:ok, minimum_firmware, rest} <- take_firmware(rest),
             {:ok, required_capabilities, rest} <- take_capabilities(rest),
             <<section_count::16, rest::binary>> <- rest,
             {:ok, sections, rest} <- take_sections(rest, section_count, []),
             {:ok, presented_hash, trailing} <- take_lp(rest),
             :ok <- ensure(trailing == <<>>, :trailing_bytes),
             :ok <- fixed_binary(presented_hash, @hash_size, :invalid_manifest_hash),
             body_size = byte_size(bytes) - @hash_size - 2,
             body = binary_part(bytes, 0, body_size),
             computed_hash = :crypto.hash(:sha256, body),
             :ok <- ensure(secure_equal(computed_hash, presented_hash), :manifest_hash_mismatch),
             attrs = %{
               device_id: device_id,
               credential_epoch: credential_epoch,
               generation: generation,
               minimum_firmware: minimum_firmware,
               required_capabilities: required_capabilities,
               sections: sections
             },
             {:ok, canonical} <- encode(attrs),
             :ok <- ensure(canonical == bytes, :noncanonical_manifest) do
          {:ok,
           Map.merge(attrs, %{
             desired_state_version: desired_state_version,
             section_set_version: section_set_version,
             bytes: bytes,
             hash: presented_hash,
             complete_hash: presented_hash
           })}
        else
          {:error, _reason} = error -> error
          _ -> {:error, :truncated}
        end
    end
  end

  def decode(_), do: {:error, :invalid_manifest}

  @doc "Return the complete hash committed at the end of a canonical manifest."
  def hash(bytes) when is_binary(bytes) and byte_size(bytes) >= @hash_size + 2 do
    body_size = byte_size(bytes) - @hash_size - 2

    case binary_part(bytes, body_size, @hash_size + 2) do
      <<@hash_size::16, _presented::binary-size(@hash_size)>> ->
        bytes
        |> binary_part(0, body_size)
        |> then(&:crypto.hash(:sha256, &1))

      _ ->
        :crypto.hash(:sha256, bytes)
    end
  end

  def hash(bytes) when is_binary(bytes), do: :crypto.hash(:sha256, bytes)

  defp encode_firmware(nil), do: {:ok, <<0>>}

  defp encode_firmware(firmware) when is_binary(firmware) do
    with :ok <- validate_semver(firmware) do
      {:ok, <<1, byte_size(firmware)::16, firmware::binary>>}
    end
  end

  defp encode_firmware(_), do: {:error, :invalid_semver}

  defp take_firmware(<<0, rest::binary>>), do: {:ok, nil, rest}

  defp take_firmware(<<1, rest::binary>>) do
    with {:ok, firmware, trailing} <- take_lp(rest),
         :ok <- validate_semver(firmware) do
      {:ok, firmware, trailing}
    end
  end

  defp take_firmware(<<_flag, _rest::binary>>), do: {:error, :invalid_firmware_presence}
  defp take_firmware(_), do: {:error, :truncated}

  defp validate_semver(value) do
    cond do
      byte_size(value) == 0 or byte_size(value) > @max_firmware_size ->
        {:error, :invalid_semver}

      not String.valid?(value) or String.normalize(value, :nfc) != value ->
        {:error, :invalid_semver}

      String.contains?(value, "+") ->
        {:error, :invalid_semver}

      true ->
        case Version.parse(value) do
          {:ok, version} ->
            if to_string(version) == value, do: :ok, else: {:error, :invalid_semver}

          :error ->
            {:error, :invalid_semver}
        end
    end
  end

  defp encode_capabilities(capabilities) when is_list(capabilities) do
    with :ok <- ensure_proper_list(capabilities),
         :ok <- ensure(length(capabilities) <= Contract.max_capabilities(), :too_many_capabilities),
         {:ok, normalized} <- normalize_capabilities(capabilities),
         :ok <- ensure_capability_order(normalized) do
      encoded =
        Enum.map(normalized, fn %{id: id, version: version} -> <<id::16, version::16>> end)

      {:ok, IO.iodata_to_binary([<<length(normalized)::16>>, encoded])}
    end
  end

  defp encode_capabilities(_), do: {:error, :invalid_capabilities}

  defp take_capabilities(<<count::16, rest::binary>>) do
    with :ok <- ensure(count <= Contract.max_capabilities(), :too_many_capabilities),
         {:ok, capabilities, trailing} <- take_capability_entries(rest, count, []),
         {:ok, normalized} <- normalize_capabilities(capabilities),
         :ok <- ensure_capability_order(normalized) do
      {:ok, capabilities, trailing}
    end
  end

  defp take_capabilities(_), do: {:error, :truncated}

  defp take_capability_entries(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_capability_entries(<<id::16, version::16, rest::binary>>, count, acc) do
    with {:ok, name, expected_version} <- Contract.capability_name(id),
         :ok <- ensure(version == expected_version, :unsupported_capability_version) do
      take_capability_entries(rest, count - 1, [{name, version} | acc])
    end
  end

  defp take_capability_entries(_rest, _count, _acc), do: {:error, :truncated}

  defp normalize_capabilities(capabilities) do
    capabilities
    |> Enum.reduce_while({:ok, []}, fn
      {name, version}, {:ok, acc} when is_atom(name) and is_integer(version) ->
        case Contract.capability_code(name) do
          {:ok, id, expected_version} when version == expected_version ->
            {:cont, {:ok, [%{name: name, id: id, version: version} | acc]}}

          {:ok, _id, _expected_version} ->
            {:halt, {:error, :unsupported_capability_version}}

          {:error, _reason} ->
            {:halt, {:error, :unknown_capability}}
        end

      _, _acc ->
        {:halt, {:error, :invalid_capabilities}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp ensure_capability_order([]), do: :ok

  defp ensure_capability_order(capabilities) do
    ids = Enum.map(capabilities, & &1.id)

    cond do
      length(Enum.uniq(ids)) != length(ids) -> {:error, :duplicate_capability}
      ids != Enum.sort(ids) -> {:error, :capabilities_out_of_order}
      true -> :ok
    end
  end

  defp encode_sections(sections) when is_list(sections) do
    with :ok <- ensure_proper_list(sections),
         :ok <- validate_complete_sections(sections),
         {:ok, total} <- section_content_total(sections),
         :ok <- ensure(total <= Contract.max_generation_size(), :generation_content_too_large),
         {:ok, encoded} <- encode_section_descriptors(sections) do
      {:ok, encoded}
    end
  end

  defp encode_sections(_), do: {:error, :invalid_sections}

  defp section_content_total(sections) do
    Enum.reduce_while(sections, {:ok, 0}, fn section, {:ok, total} ->
      case Map.get(section, :content_length) do
        content_length when is_integer(content_length) ->
          {:cont, {:ok, total + content_length}}

        _invalid ->
          {:halt, {:error, :invalid_content_length}}
      end
    end)
  end

  defp encode_section_descriptors(sections) do
    sections
    |> Enum.reduce_while({:ok, []}, fn section, {:ok, acc} ->
      case Section.encode_descriptor(section) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, encoded |> Enum.reverse() |> IO.iodata_to_binary()}
      error -> error
    end
  end

  defp take_sections(rest, count, acc) do
    with :ok <- ensure(count == length(Contract.sections()), :missing_section) do
      do_take_sections(rest, count, acc)
    end
  end

  defp do_take_sections(rest, 0, acc) do
    sections = Enum.reverse(acc)

    with :ok <- validate_complete_sections(sections),
         total <- Enum.reduce(sections, 0, &(&1.content_length + &2)),
         :ok <- ensure(total <= Contract.max_generation_size(), :generation_content_too_large) do
      {:ok, sections, rest}
    end
  end

  defp do_take_sections(rest, count, acc) do
    with {:ok, section, trailing} <- Section.take_descriptor(rest) do
      do_take_sections(trailing, count - 1, [section | acc])
    end
  end

  defp validate_complete_sections(sections) do
    names = Enum.map(sections, &Map.get(&1, :name))
    expected = Contract.sections()

    cond do
      Enum.any?(names, &(&1 not in expected)) ->
        {:error, :unknown_section}

      length(Enum.uniq(names)) != length(names) ->
        {:error, :duplicate_section}

      length(names) < length(expected) ->
        {:error, :missing_section}

      length(names) > length(expected) ->
        {:error, :duplicate_section}

      names != expected ->
        {:error, :sections_out_of_order}

      true ->
        :ok
    end
  end

  defp strip_domain_version(bytes) do
    domain = Contract.manifest_domain()
    size = byte_size(domain)

    case bytes do
      <<presented::binary-size(size), version, rest::binary>> ->
        cond do
          presented != domain -> {:error, :manifest_domain_mismatch}
          version != Contract.version() -> {:error, :unsupported_manifest_version}
          true -> {:ok, rest}
        end

      _ ->
        {:error, :truncated}
    end
  end

  defp take_lp(<<length::16, rest::binary>>) when byte_size(rest) >= length do
    <<value::binary-size(length), trailing::binary>> = rest
    {:ok, value, trailing}
  end

  defp take_lp(_), do: {:error, :truncated}

  defp exact_keys(attrs, expected) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected), do: :ok, else: {:error, :unknown_field}
  end

  defp fixed_binary(value, size, _error) when is_binary(value) and byte_size(value) == size,
    do: :ok

  defp fixed_binary(_value, _size, error), do: {:error, error}

  defp u32(value, _error) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32(_value, error), do: {:error, error}

  defp positive_u64(value, _error)
       when is_integer(value) and value > 0 and value <= @u64_max,
       do: :ok

  defp positive_u64(_value, error), do: {:error, error}

  defp ensure_proper_list([]), do: :ok
  defp ensure_proper_list([_ | rest]), do: ensure_proper_list(rest)
  defp ensure_proper_list(_), do: {:error, :invalid_list}

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}

  defp secure_equal(left, right) do
    is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) and
      :crypto.hash_equals(left, right)
  end
end
