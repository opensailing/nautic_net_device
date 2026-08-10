defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages do
  @moduledoc """
  Strict authenticated control payload codecs for Desired State v1.

  Every payload has its own ASCII domain, the frozen payload version, and the registered
  message-type byte before its body. Decoding is expected-type-specific and consumes the
  complete input.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Checkpoint,
    Command,
    Manifest,
    Receipt
  }

  @device_id_size 16
  @incarnation_id_size 16
  @hash_size 32
  @secret_ref_size 16
  @u32_max 0xFFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF
  @database_int_max 9_223_372_036_854_775_807
  @max_firmware_size 80
  @max_git_sha_size 40

  @identity_keys [:device_id, :credential_epoch, :boot_id, :storage_epoch]
  @durable_identity_keys [:device_id, :credential_epoch, :storage_epoch]
  @command_fence_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :required_generation,
    :required_manifest_hash,
    :command_epoch,
    :command_sequence,
    :command_id
  ]

  @doc "Encode one registered authenticated payload."
  def encode(type, attrs) when is_atom(type) and is_map(attrs) do
    with {:ok, type_code, _direction} <- Contract.message_type(type),
         {:ok, body} <- encode_body(type, attrs) do
      {:ok, Contract.payload_domain(type) <> <<Contract.version(), type_code>> <> body}
    end
  end

  def encode(type, _attrs) when is_atom(type) do
    case Contract.message_type(type) do
      {:ok, _type_code, _direction} -> {:error, :invalid_payload}
      {:error, _reason} = error -> error
    end
  end

  def encode(_type, _attrs), do: {:error, :unsupported_message_type}

  @doc "Decode exactly the expected registered authenticated payload."
  def decode(type, bytes) when is_atom(type) and is_binary(bytes) do
    with {:ok, rest} <- strip_header(type, bytes),
         {:ok, attrs, trailing} <- decode_body(type, rest),
         :ok <- ensure(trailing == <<>>, :trailing_bytes),
         {:ok, canonical} <- encode(type, attrs),
         :ok <- ensure(canonical == bytes, :noncanonical_payload) do
      {:ok, attrs}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  def decode(type, _bytes) when is_atom(type) do
    case Contract.message_type(type) do
      {:ok, _type_code, _direction} -> {:error, :invalid_payload}
      {:error, _reason} = error -> error
    end
  end

  def decode(_type, _bytes), do: {:error, :unsupported_message_type}

  defp encode_body(:control_accept, attrs), do: encode_control_accept(attrs)
  defp encode_body(:readiness, attrs), do: encode_readiness(attrs)
  defp encode_body(:manifest_delivery, attrs), do: encode_manifest_delivery(attrs)
  defp encode_body(:section_chunk, attrs), do: encode_section_chunk(attrs)
  defp encode_body(:resume, attrs), do: encode_resume(attrs)
  defp encode_body(:secret_delivery, attrs), do: encode_secret_delivery(attrs)
  defp encode_body(:ack, attrs), do: encode_ack(attrs)
  defp encode_body(:command_delivery, attrs), do: encode_command_delivery(attrs)
  defp encode_body(:command_ack, attrs), do: encode_command_ack(attrs)
  defp encode_body(:delivery_receipt, attrs), do: encode_delivery_receipt(attrs)
  defp encode_body(:checkpoint_submission, attrs), do: encode_checkpoint_submission(attrs)
  defp encode_body(:checkpoint_hydration, attrs), do: encode_checkpoint_hydration(attrs)
  defp encode_body(_type, _attrs), do: {:error, :unsupported_message_type}

  defp decode_body(:control_accept, bytes), do: decode_control_accept(bytes)
  defp decode_body(:readiness, bytes), do: decode_readiness(bytes)
  defp decode_body(:manifest_delivery, bytes), do: decode_manifest_delivery(bytes)
  defp decode_body(:section_chunk, bytes), do: decode_section_chunk(bytes)
  defp decode_body(:resume, bytes), do: decode_resume(bytes)
  defp decode_body(:secret_delivery, bytes), do: decode_secret_delivery(bytes)
  defp decode_body(:ack, bytes), do: decode_ack(bytes)
  defp decode_body(:command_delivery, bytes), do: decode_command_delivery(bytes)
  defp decode_body(:command_ack, bytes), do: decode_command_ack(bytes)
  defp decode_body(:delivery_receipt, bytes), do: decode_delivery_receipt(bytes)
  defp decode_body(:checkpoint_submission, bytes), do: decode_checkpoint_submission(bytes)
  defp decode_body(:checkpoint_hydration, bytes), do: decode_checkpoint_hydration(bytes)
  defp decode_body(_type, _bytes), do: {:error, :unsupported_message_type}

  # control_accept

  defp encode_control_accept(attrs) do
    expected = [
      :device_id,
      :credential_epoch,
      :selected_control_version,
      :selected_desired_version,
      :offer_hash
    ]

    with :ok <- exact_keys(attrs, expected, :invalid_control_accept),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <- selected_version(attrs.selected_control_version),
         :ok <- selected_version(attrs.selected_desired_version),
         :ok <- fixed_binary(attrs.offer_hash, @hash_size, :invalid_offer_hash) do
      {:ok,
       <<attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32, attrs.selected_control_version::16,
         attrs.selected_desired_version::16, attrs.offer_hash::binary-size(@hash_size)>>}
    end
  end

  defp decode_control_accept(
         <<device_id::binary-size(@device_id_size), credential_epoch::32, selected_control_version::16,
           selected_desired_version::16, offer_hash::binary-size(@hash_size), rest::binary>>
       ) do
    attrs = %{
      device_id: device_id,
      credential_epoch: credential_epoch,
      selected_control_version: selected_control_version,
      selected_desired_version: selected_desired_version,
      offer_hash: offer_hash
    }

    with {:ok, _encoded} <- encode_body(:control_accept, attrs), do: {:ok, attrs, rest}
  end

  defp decode_control_accept(_), do: {:error, :truncated}

  # readiness

  defp encode_readiness(attrs) do
    expected =
      @identity_keys ++
        [
          :selected_control_version,
          :selected_desired_version,
          :offer_hash,
          :firmware_version,
          :firmware_git_sha,
          :capabilities,
          :effective
        ]

    with :ok <- exact_keys(attrs, expected, :invalid_readiness),
         {:ok, identity} <- encode_identity(attrs),
         :ok <- selected_version(attrs.selected_control_version),
         :ok <- selected_version(attrs.selected_desired_version),
         :ok <- fixed_binary(attrs.offer_hash, @hash_size, :invalid_offer_hash),
         {:ok, firmware_version} <- encode_firmware_version(attrs.firmware_version),
         {:ok, firmware_git_sha} <- encode_git_sha(attrs.firmware_git_sha),
         {:ok, capabilities} <- encode_capabilities(attrs.capabilities),
         {:ok, effective} <- encode_effective_identity(attrs.effective) do
      {:ok,
       identity <>
         <<attrs.selected_control_version::16, attrs.selected_desired_version::16,
           attrs.offer_hash::binary-size(@hash_size)>> <>
         firmware_version <> firmware_git_sha <> capabilities <> effective}
    end
  end

  defp decode_readiness(bytes) do
    with {:ok, identity, rest} <- take_identity(bytes),
         <<selected_control_version::16, selected_desired_version::16, offer_hash::binary-size(@hash_size),
           rest::binary>> <- rest,
         {:ok, firmware_version, rest} <- take_lp(rest),
         {:ok, firmware_git_sha, rest} <- take_lp(rest),
         {:ok, capabilities, rest} <- take_capabilities(rest),
         {:ok, effective, rest} <- take_effective_identity(rest),
         attrs =
           Map.merge(identity, %{
             selected_control_version: selected_control_version,
             selected_desired_version: selected_desired_version,
             offer_hash: offer_hash,
             firmware_version: firmware_version,
             firmware_git_sha: firmware_git_sha,
             capabilities: capabilities,
             effective: effective
           }),
         {:ok, _encoded} <- encode_body(:readiness, attrs) do
      {:ok, attrs, rest}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  # manifest_delivery

  defp encode_manifest_delivery(attrs) do
    expected = @identity_keys ++ [:generation, :manifest_hash, :manifest]

    with :ok <- exact_keys(attrs, expected, :invalid_manifest_delivery),
         {:ok, identity} <- encode_identity(attrs),
         :ok <- positive_database_int(attrs.generation, :invalid_generation),
         :ok <- fixed_binary(attrs.manifest_hash, @hash_size, :invalid_manifest_hash),
         :ok <- manifest_size(attrs.manifest),
         {:ok, manifest} <- Manifest.decode(attrs.manifest),
         :ok <-
           ensure(
             secure_equal(manifest.hash, attrs.manifest_hash),
             :manifest_hash_mismatch
           ),
         :ok <- validate_manifest_binding(attrs, manifest) do
      {:ok,
       identity <>
         <<attrs.generation::64, attrs.manifest_hash::binary-size(@hash_size), byte_size(attrs.manifest)::32,
           attrs.manifest::binary>>}
    end
  end

  defp decode_manifest_delivery(bytes) do
    with {:ok, identity, rest} <- take_identity(bytes),
         <<generation::64, manifest_hash::binary-size(@hash_size), manifest_length::32, rest::binary>> <- rest,
         true <- byte_size(rest) >= manifest_length || {:error, :truncated},
         <<manifest::binary-size(manifest_length), trailing::binary>> <- rest,
         attrs =
           Map.merge(identity, %{
             generation: generation,
             manifest_hash: manifest_hash,
             manifest: manifest
           }),
         {:ok, _encoded} <- encode_body(:manifest_delivery, attrs) do
      {:ok, attrs, trailing}
    else
      false -> {:error, :truncated}
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  # section_chunk

  defp encode_section_chunk(attrs) do
    expected =
      @identity_keys ++
        [
          :generation,
          :manifest_hash,
          :section,
          :section_schema_version,
          :section_hash,
          :total_content_length,
          :chunk_index,
          :chunk_count,
          :chunk_offset,
          :chunk
        ]

    with :ok <- exact_keys(attrs, expected, :invalid_section_chunk),
         {:ok, identity} <- encode_identity(attrs),
         :ok <- validate_generation_hash(attrs),
         {:ok, section_code} <- section_identity(attrs.section, attrs.section_schema_version),
         :ok <- fixed_binary(attrs.section_hash, @hash_size, :invalid_section_hash),
         :ok <- validate_chunk_geometry(attrs) do
      {:ok,
       identity <>
         <<attrs.generation::64, attrs.manifest_hash::binary-size(@hash_size), section_code,
           attrs.section_schema_version::16, attrs.section_hash::binary-size(@hash_size),
           attrs.total_content_length::64, attrs.chunk_index::32, attrs.chunk_count::32, attrs.chunk_offset::64,
           byte_size(attrs.chunk)::32, attrs.chunk::binary>>}
    end
  end

  defp decode_section_chunk(bytes) do
    with {:ok, identity, rest} <- take_identity(bytes),
         <<generation::64, manifest_hash::binary-size(@hash_size), section_code, section_schema_version::16,
           section_hash::binary-size(@hash_size), total_content_length::64, chunk_index::32, chunk_count::32,
           chunk_offset::64, chunk_length::32, rest::binary>> <- rest,
         true <- byte_size(rest) >= chunk_length || {:error, :truncated},
         <<chunk::binary-size(chunk_length), trailing::binary>> <- rest,
         section when is_atom(section) <- Contract.section_name(section_code),
         attrs =
           Map.merge(identity, %{
             generation: generation,
             manifest_hash: manifest_hash,
             section: section,
             section_schema_version: section_schema_version,
             section_hash: section_hash,
             total_content_length: total_content_length,
             chunk_index: chunk_index,
             chunk_count: chunk_count,
             chunk_offset: chunk_offset,
             chunk: chunk
           }),
         {:ok, _encoded} <- encode_body(:section_chunk, attrs) do
      {:ok, attrs, trailing}
    else
      false -> {:error, :truncated}
      {:error, _reason} = error -> error
      _ -> {:error, :unknown_section}
    end
  end

  # resume

  defp encode_resume(attrs) do
    expected = @identity_keys ++ [:generation, :manifest_hash, :incomplete_sections]

    with :ok <- exact_keys(attrs, expected, :invalid_resume),
         {:ok, identity} <- encode_identity(attrs),
         :ok <- validate_generation_hash(attrs),
         {:ok, sections} <- encode_incomplete_sections(attrs.incomplete_sections) do
      {:ok,
       identity <>
         <<attrs.generation::64, attrs.manifest_hash::binary-size(@hash_size), length(attrs.incomplete_sections)::16>> <>
         sections}
    end
  end

  defp decode_resume(bytes) do
    with {:ok, identity, rest} <- take_identity(bytes),
         <<generation::64, manifest_hash::binary-size(@hash_size), section_count::16, rest::binary>> <- rest,
         {:ok, incomplete_sections, trailing} <-
           take_incomplete_sections(rest, section_count, []),
         attrs =
           Map.merge(identity, %{
             generation: generation,
             manifest_hash: manifest_hash,
             incomplete_sections: incomplete_sections
           }),
         {:ok, _encoded} <- encode_body(:resume, attrs) do
      {:ok, attrs, trailing}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  # secret_delivery

  defp encode_secret_delivery(attrs) do
    expected =
      @identity_keys ++
        [
          :generation,
          :manifest_hash,
          :section,
          :section_schema_version,
          :section_hash,
          :secret_kind,
          :digest_key_id,
          :secret_ref,
          :secret_digest,
          :secret
        ]

    with :ok <- exact_keys(attrs, expected, :invalid_secret_delivery),
         {:ok, identity} <- encode_identity(attrs),
         :ok <- validate_generation_hash(attrs),
         {:ok, section_code} <- section_identity(attrs.section, attrs.section_schema_version),
         :ok <- ensure(attrs.section == :wifi, :secret_not_allowed),
         :ok <- fixed_binary(attrs.section_hash, @hash_size, :invalid_section_hash),
         {:ok, secret_kind} <- Contract.secret_kind(attrs.secret_kind),
         :ok <- u32(attrs.digest_key_id, :invalid_digest_key_id),
         :ok <- nonzero_binary(attrs.secret_ref, @secret_ref_size, :invalid_secret_reference),
         :ok <- fixed_binary(attrs.secret_digest, @hash_size, :invalid_secret_digest),
         :ok <- validate_secret(attrs.secret) do
      {:ok,
       identity <>
         <<attrs.generation::64, attrs.manifest_hash::binary-size(@hash_size), section_code,
           attrs.section_schema_version::16, attrs.section_hash::binary-size(@hash_size), secret_kind,
           attrs.digest_key_id::32, attrs.secret_ref::binary-size(@secret_ref_size),
           attrs.secret_digest::binary-size(@hash_size), byte_size(attrs.secret)::16, attrs.secret::binary>>}
    end
  end

  defp decode_secret_delivery(bytes) do
    with {:ok, identity, rest} <- take_identity(bytes),
         <<generation::64, manifest_hash::binary-size(@hash_size), section_code, section_schema_version::16,
           section_hash::binary-size(@hash_size), secret_kind_code, digest_key_id::32,
           secret_ref::binary-size(@secret_ref_size), secret_digest::binary-size(@hash_size), secret_length::16,
           rest::binary>> <- rest,
         true <- byte_size(rest) >= secret_length || {:error, :truncated},
         <<secret::binary-size(secret_length), trailing::binary>> <- rest,
         section when is_atom(section) <- Contract.section_name(section_code),
         {:ok, secret_kind} <- Contract.secret_kind(secret_kind_code),
         attrs =
           Map.merge(identity, %{
             generation: generation,
             manifest_hash: manifest_hash,
             section: section,
             section_schema_version: section_schema_version,
             section_hash: section_hash,
             secret_kind: secret_kind,
             digest_key_id: digest_key_id,
             secret_ref: secret_ref,
             secret_digest: secret_digest,
             secret: secret
           }),
         {:ok, _encoded} <- encode_body(:secret_delivery, attrs) do
      {:ok, attrs, trailing}
    else
      false -> {:error, :truncated}
      {:error, _reason} = error -> error
      _ -> {:error, :unknown_section}
    end
  end

  # ack

  defp encode_ack(%{status: :staged} = attrs) do
    expected = @identity_keys ++ [:generation, :manifest_hash, :status, :sections]

    with :ok <- exact_keys(attrs, expected, :invalid_staged_shape),
         {:ok, common} <- encode_ack_common(attrs),
         {:ok, status} <- Contract.ack_status(:staged),
         {:ok, sections} <- encode_section_summaries(attrs.sections) do
      {:ok, common <> <<status, length(attrs.sections)::16>> <> sections}
    end
  end

  defp encode_ack(%{status: :effective} = attrs) do
    expected = @identity_keys ++ [:generation, :manifest_hash, :status]

    with :ok <- exact_keys(attrs, expected, :invalid_rejection_shape),
         {:ok, common} <- encode_ack_common(attrs),
         {:ok, status} <- Contract.ack_status(:effective) do
      {:ok, common <> <<status>>}
    end
  end

  defp encode_ack(%{status: :rejected} = attrs) do
    expected =
      @identity_keys ++
        [:generation, :manifest_hash, :status, :phase, :error_code, :retryable, :section]

    with :ok <- exact_keys(attrs, expected, :invalid_rejection_shape),
         {:ok, common} <- encode_ack_common(attrs),
         {:ok, status} <- Contract.ack_status(:rejected),
         {:ok, phase} <- Contract.rejection_phase(attrs.phase),
         {:ok, error_code} <- Contract.rejection_code(attrs.error_code),
         :ok <- ensure(is_boolean(attrs.retryable), :invalid_rejection_shape),
         {:ok, section} <- encode_rejection_section(attrs.section) do
      retryable = if attrs.retryable, do: 1, else: 0
      {:ok, common <> <<status, phase, error_code::16, retryable>> <> section}
    end
  end

  defp encode_ack(%{status: _unknown}), do: {:error, :unknown_ack_status}
  defp encode_ack(_attrs), do: {:error, :invalid_ack}

  defp decode_ack(bytes) do
    with {:ok, identity, rest} <- take_identity(bytes),
         <<generation::64, manifest_hash::binary-size(@hash_size), status_code, rest::binary>> <-
           rest,
         {:ok, status} <- Contract.ack_status(status_code),
         {:ok, attrs, trailing} <-
           decode_ack_status(status, identity, generation, manifest_hash, rest),
         {:ok, _encoded} <- encode_body(:ack, attrs) do
      {:ok, attrs, trailing}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  defp decode_ack_status(
         :staged,
         identity,
         generation,
         manifest_hash,
         <<count::16, rest::binary>>
       ) do
    with {:ok, sections, trailing} <- take_section_summaries(rest, count, []) do
      {:ok,
       Map.merge(identity, %{
         generation: generation,
         manifest_hash: manifest_hash,
         status: :staged,
         sections: sections
       }), trailing}
    end
  end

  defp decode_ack_status(:staged, _identity, _generation, _manifest_hash, _),
    do: {:error, :truncated}

  defp decode_ack_status(:effective, identity, generation, manifest_hash, rest) do
    {:ok,
     Map.merge(identity, %{
       generation: generation,
       manifest_hash: manifest_hash,
       status: :effective
     }), rest}
  end

  defp decode_ack_status(
         :rejected,
         identity,
         generation,
         manifest_hash,
         <<phase_code, error_code::16, retryable_code, rest::binary>>
       ) do
    with {:ok, phase} <- Contract.rejection_phase(phase_code),
         {:ok, error_code} <- Contract.rejection_code(error_code),
         {:ok, retryable} <- decode_boolean(retryable_code),
         {:ok, section, trailing} <- take_rejection_section(rest) do
      {:ok,
       Map.merge(identity, %{
         generation: generation,
         manifest_hash: manifest_hash,
         status: :rejected,
         phase: phase,
         error_code: error_code,
         retryable: retryable,
         section: section
       }), trailing}
    end
  end

  defp decode_ack_status(:rejected, _identity, _generation, _manifest_hash, _),
    do: {:error, :truncated}

  defp encode_ack_common(attrs) do
    with {:ok, identity} <- encode_identity(attrs),
         :ok <- validate_generation_hash(attrs) do
      {:ok, identity <> <<attrs.generation::64, attrs.manifest_hash::binary-size(@hash_size)>>}
    end
  end

  # command_delivery

  defp encode_command_delivery(attrs) do
    expected =
      @command_fence_keys ++
        [:expires_at_ms, :payload_hash, :command_hash, :payload]

    with :ok <- exact_keys(attrs, expected, :invalid_command_delivery),
         {:ok, fence} <- normalize_command_fence(attrs),
         :ok <- database_int(attrs.expires_at_ms, :invalid_expires_at_ms),
         :ok <- fixed_binary(attrs.payload_hash, @hash_size, :invalid_payload_hash),
         :ok <- fixed_binary(attrs.command_hash, @hash_size, :invalid_command_hash),
         {:ok, expected_payload_hash} <- Command.payload_hash(attrs.payload),
         :ok <-
           ensure(
             secure_equal(expected_payload_hash, attrs.payload_hash),
             :payload_hash_mismatch
           ),
         command_record =
           Map.merge(fence, %{
             expires_at_ms: attrs.expires_at_ms,
             payload_hash: attrs.payload_hash
           }),
         {:ok, expected_command_hash} <- Command.hash(command_record),
         :ok <-
           ensure(
             secure_equal(expected_command_hash, attrs.command_hash),
             :command_hash_mismatch
           ) do
      {:ok,
       encode_command_fence(fence) <>
         <<attrs.expires_at_ms::64, attrs.payload_hash::binary-size(@hash_size),
           attrs.command_hash::binary-size(@hash_size), byte_size(attrs.payload)::32, attrs.payload::binary>>}
    end
  end

  defp decode_command_delivery(
         <<device_id::binary-size(@device_id_size), credential_epoch::32,
           storage_epoch::binary-size(@incarnation_id_size), required_generation::64,
           required_manifest_hash::binary-size(@hash_size), command_epoch::32, command_sequence::64,
           command_id::binary-size(@device_id_size), expires_at_ms::64, payload_hash::binary-size(@hash_size),
           command_hash::binary-size(@hash_size), payload_length::32, rest::binary>>
       ) do
    with true <- byte_size(rest) >= payload_length || {:error, :truncated},
         <<payload::binary-size(payload_length), trailing::binary>> <- rest,
         attrs = %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           required_generation: required_generation,
           required_manifest_hash: required_manifest_hash,
           command_epoch: command_epoch,
           command_sequence: command_sequence,
           command_id: command_id,
           expires_at_ms: expires_at_ms,
           payload_hash: payload_hash,
           command_hash: command_hash,
           payload: payload
         },
         {:ok, _encoded} <- encode_body(:command_delivery, attrs) do
      {:ok, attrs, trailing}
    else
      false -> {:error, :truncated}
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  defp decode_command_delivery(_), do: {:error, :truncated}

  # command_ack

  defp encode_command_ack(attrs) do
    expected = @command_fence_keys ++ [:command_hash, :status, :reason, :result_hash, :result]

    with :ok <- exact_keys(attrs, expected, :invalid_command_ack),
         {:ok, fence} <- normalize_command_fence(attrs),
         :ok <- fixed_binary(attrs.command_hash, @hash_size, :invalid_command_hash),
         {:ok, status_code} <- command_status_code(attrs.status),
         {:ok, reason_code} <- command_reason_code(attrs.reason),
         :ok <- fixed_binary(attrs.result_hash, @hash_size, :invalid_result_hash),
         {:ok, expected_result_hash} <-
           Command.result_hash(%{
             status: attrs.status,
             reason: attrs.reason,
             result: attrs.result
           }),
         :ok <-
           ensure(
             secure_equal(expected_result_hash, attrs.result_hash),
             :result_hash_mismatch
           ) do
      {:ok,
       encode_command_fence(fence) <>
         <<attrs.command_hash::binary-size(@hash_size), status_code, reason_code,
           attrs.result_hash::binary-size(@hash_size), byte_size(attrs.result)::32, attrs.result::binary>>}
    end
  end

  defp decode_command_ack(
         <<device_id::binary-size(@device_id_size), credential_epoch::32,
           storage_epoch::binary-size(@incarnation_id_size), required_generation::64,
           required_manifest_hash::binary-size(@hash_size), command_epoch::32, command_sequence::64,
           command_id::binary-size(@device_id_size), command_hash::binary-size(@hash_size), status_code, reason_code,
           result_hash::binary-size(@hash_size), result_length::32, rest::binary>>
       ) do
    with {:ok, status} <- Contract.command_status(status_code),
         {:ok, reason} <- Contract.command_reason(reason_code),
         true <- byte_size(rest) >= result_length || {:error, :truncated},
         <<result::binary-size(result_length), trailing::binary>> <- rest,
         attrs = %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           required_generation: required_generation,
           required_manifest_hash: required_manifest_hash,
           command_epoch: command_epoch,
           command_sequence: command_sequence,
           command_id: command_id,
           command_hash: command_hash,
           status: status,
           reason: reason,
           result_hash: result_hash,
           result: result
         },
         {:ok, _encoded} <- encode_body(:command_ack, attrs) do
      {:ok, attrs, trailing}
    else
      false -> {:error, :truncated}
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  defp decode_command_ack(_), do: {:error, :truncated}

  # delivery_receipt

  defp encode_delivery_receipt(attrs) do
    expected =
      @durable_identity_keys ++
        [:stream, :sequence, :payload_hash, :cumulative_sequence, :receipt_hash]

    with :ok <- exact_keys(attrs, expected, :invalid_delivery_receipt),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <-
           nonzero_binary(
             attrs.storage_epoch,
             @incarnation_id_size,
             :invalid_storage_epoch
           ),
         {:ok, stream_code} <- delivery_stream_code(attrs.stream),
         :ok <- positive_database_int(attrs.sequence, :invalid_delivery_sequence),
         :ok <- fixed_binary(attrs.payload_hash, @hash_size, :invalid_payload_hash),
         :ok <- database_int(attrs.cumulative_sequence, :invalid_cumulative_sequence),
         :ok <- fixed_binary(attrs.receipt_hash, @hash_size, :invalid_receipt_hash),
         {:ok, expected_hash} <- Receipt.hash(Map.delete(attrs, :receipt_hash)),
         :ok <- ensure(secure_equal(expected_hash, attrs.receipt_hash), :receipt_hash_mismatch) do
      {:ok,
       <<attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32,
         attrs.storage_epoch::binary-size(@incarnation_id_size), stream_code, attrs.sequence::64,
         attrs.payload_hash::binary-size(@hash_size), attrs.cumulative_sequence::64,
         attrs.receipt_hash::binary-size(@hash_size)>>}
    end
  end

  defp decode_delivery_receipt(
         <<device_id::binary-size(@device_id_size), credential_epoch::32,
           storage_epoch::binary-size(@incarnation_id_size), stream_code, sequence::64,
           payload_hash::binary-size(@hash_size), cumulative_sequence::64, receipt_hash::binary-size(@hash_size),
           rest::binary>>
       ) do
    with {:ok, stream} <- Contract.delivery_stream(stream_code),
         attrs = %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           stream: stream,
           sequence: sequence,
           payload_hash: payload_hash,
           cumulative_sequence: cumulative_sequence,
           receipt_hash: receipt_hash
         },
         {:ok, _encoded} <- encode_body(:delivery_receipt, attrs) do
      {:ok, attrs, rest}
    end
  end

  defp decode_delivery_receipt(_), do: {:error, :truncated}

  # checkpoint_submission

  defp encode_checkpoint_submission(attrs) do
    expected =
      @durable_identity_keys ++
        [
          :sequence,
          :kind,
          :schema_version,
          :source_generation,
          :parent_hash,
          :content_hash,
          :checkpoint_hash,
          :content
        ]

    with :ok <- exact_keys(attrs, expected, :invalid_checkpoint_submission),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <-
           nonzero_binary(
             attrs.storage_epoch,
             @incarnation_id_size,
             :invalid_storage_epoch
           ),
         :ok <- positive_database_int(attrs.sequence, :invalid_delivery_sequence),
         {:ok, kind_code} <- checkpoint_identity(attrs.kind, attrs.schema_version),
         :ok <- database_int(attrs.source_generation, :invalid_source_generation),
         :ok <- fixed_binary(attrs.parent_hash, @hash_size, :invalid_parent_hash),
         :ok <- fixed_binary(attrs.content_hash, @hash_size, :invalid_checkpoint_content_hash),
         :ok <- fixed_binary(attrs.checkpoint_hash, @hash_size, :invalid_checkpoint_hash),
         {:ok, expected_content_hash} <-
           Checkpoint.content_hash(attrs.kind, attrs.schema_version, attrs.content),
         :ok <-
           ensure(
             secure_equal(expected_content_hash, attrs.content_hash),
             :checkpoint_content_hash_mismatch
           ),
         {:ok, expected_checkpoint_hash} <-
           Checkpoint.hash(Map.drop(attrs, [:checkpoint_hash, :content])),
         :ok <-
           ensure(
             secure_equal(expected_checkpoint_hash, attrs.checkpoint_hash),
             :checkpoint_hash_mismatch
           ) do
      {:ok,
       <<attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32,
         attrs.storage_epoch::binary-size(@incarnation_id_size), attrs.sequence::64, kind_code,
         attrs.schema_version::16, attrs.source_generation::64, attrs.parent_hash::binary-size(@hash_size),
         attrs.content_hash::binary-size(@hash_size), attrs.checkpoint_hash::binary-size(@hash_size),
         byte_size(attrs.content)::32, attrs.content::binary>>}
    end
  end

  defp decode_checkpoint_submission(
         <<device_id::binary-size(@device_id_size), credential_epoch::32,
           storage_epoch::binary-size(@incarnation_id_size), sequence::64, kind_code, schema_version::16,
           source_generation::64, parent_hash::binary-size(@hash_size), content_hash::binary-size(@hash_size),
           checkpoint_hash::binary-size(@hash_size), content_length::32, rest::binary>>
       ) do
    with {:ok, kind, _expected_schema} <- Contract.checkpoint_kind(kind_code),
         true <- byte_size(rest) >= content_length || {:error, :truncated},
         <<content::binary-size(content_length), trailing::binary>> <- rest,
         attrs = %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           sequence: sequence,
           kind: kind,
           schema_version: schema_version,
           source_generation: source_generation,
           parent_hash: parent_hash,
           content_hash: content_hash,
           checkpoint_hash: checkpoint_hash,
           content: content
         },
         {:ok, _encoded} <- encode_body(:checkpoint_submission, attrs) do
      {:ok, attrs, trailing}
    else
      false -> {:error, :truncated}
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  defp decode_checkpoint_submission(_), do: {:error, :truncated}

  # checkpoint_hydration

  defp encode_checkpoint_hydration(attrs) do
    expected =
      @durable_identity_keys ++
        [
          :origin_credential_epoch,
          :origin_storage_epoch,
          :sequence,
          :kind,
          :schema_version,
          :source_generation,
          :parent_hash,
          :content_hash,
          :checkpoint_hash,
          :content
        ]

    with :ok <- exact_keys(attrs, expected, :invalid_checkpoint_hydration),
         :ok <- fixed_binary(attrs.device_id, @device_id_size, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <-
           nonzero_binary(
             attrs.storage_epoch,
             @incarnation_id_size,
             :invalid_storage_epoch
           ),
         :ok <- u32(attrs.origin_credential_epoch, :invalid_origin_credential_epoch),
         :ok <-
           nonzero_binary(
             attrs.origin_storage_epoch,
             @incarnation_id_size,
             :invalid_origin_storage_epoch
           ),
         :ok <- positive_database_int(attrs.sequence, :invalid_delivery_sequence),
         {:ok, kind_code} <- checkpoint_identity(attrs.kind, attrs.schema_version),
         :ok <- database_int(attrs.source_generation, :invalid_source_generation),
         :ok <- fixed_binary(attrs.parent_hash, @hash_size, :invalid_parent_hash),
         :ok <- fixed_binary(attrs.content_hash, @hash_size, :invalid_checkpoint_content_hash),
         :ok <- fixed_binary(attrs.checkpoint_hash, @hash_size, :invalid_checkpoint_hash),
         {:ok, expected_content_hash} <-
           Checkpoint.content_hash(attrs.kind, attrs.schema_version, attrs.content),
         :ok <-
           ensure(
             secure_equal(expected_content_hash, attrs.content_hash),
             :checkpoint_content_hash_mismatch
           ),
         {:ok, expected_checkpoint_hash} <- hydration_checkpoint_hash(attrs),
         :ok <-
           ensure(
             secure_equal(expected_checkpoint_hash, attrs.checkpoint_hash),
             :checkpoint_hash_mismatch
           ) do
      {:ok,
       <<attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32,
         attrs.storage_epoch::binary-size(@incarnation_id_size), attrs.origin_credential_epoch::32,
         attrs.origin_storage_epoch::binary-size(@incarnation_id_size), attrs.sequence::64, kind_code,
         attrs.schema_version::16, attrs.source_generation::64, attrs.parent_hash::binary-size(@hash_size),
         attrs.content_hash::binary-size(@hash_size), attrs.checkpoint_hash::binary-size(@hash_size),
         byte_size(attrs.content)::32, attrs.content::binary>>}
    end
  end

  defp decode_checkpoint_hydration(
         <<device_id::binary-size(@device_id_size), credential_epoch::32,
           storage_epoch::binary-size(@incarnation_id_size), origin_credential_epoch::32,
           origin_storage_epoch::binary-size(@incarnation_id_size), sequence::64, kind_code, schema_version::16,
           source_generation::64, parent_hash::binary-size(@hash_size), content_hash::binary-size(@hash_size),
           checkpoint_hash::binary-size(@hash_size), content_length::32, rest::binary>>
       ) do
    with {:ok, kind, _expected_schema} <- Contract.checkpoint_kind(kind_code),
         true <- byte_size(rest) >= content_length || {:error, :truncated},
         <<content::binary-size(content_length), trailing::binary>> <- rest,
         attrs = %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch,
           origin_credential_epoch: origin_credential_epoch,
           origin_storage_epoch: origin_storage_epoch,
           sequence: sequence,
           kind: kind,
           schema_version: schema_version,
           source_generation: source_generation,
           parent_hash: parent_hash,
           content_hash: content_hash,
           checkpoint_hash: checkpoint_hash,
           content: content
         },
         {:ok, _encoded} <- encode_body(:checkpoint_hydration, attrs) do
      {:ok, attrs, trailing}
    else
      false -> {:error, :truncated}
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  defp decode_checkpoint_hydration(_), do: {:error, :truncated}

  defp hydration_checkpoint_hash(attrs) do
    Checkpoint.hash(%{
      device_id: attrs.device_id,
      credential_epoch: attrs.origin_credential_epoch,
      storage_epoch: attrs.origin_storage_epoch,
      sequence: attrs.sequence,
      kind: attrs.kind,
      schema_version: attrs.schema_version,
      source_generation: attrs.source_generation,
      parent_hash: attrs.parent_hash,
      content_hash: attrs.content_hash
    })
  end

  defp delivery_stream_code(stream) when is_atom(stream) do
    case Contract.delivery_stream(stream) do
      {:ok, code} when is_integer(code) -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end

  defp delivery_stream_code(_stream), do: {:error, :unknown_delivery_stream}

  defp checkpoint_identity(kind, schema_version) do
    case Contract.checkpoint_kind(kind) do
      {:ok, code, ^schema_version} -> {:ok, code}
      {:ok, _code, _expected_schema} -> {:error, :unsupported_checkpoint_schema}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_command_fence(attrs) do
    with {:ok, device_id} <- Command.normalize_uuid(attrs.device_id, :invalid_device_id),
         :ok <- u32(attrs.credential_epoch, :invalid_credential_epoch),
         :ok <-
           nonzero_binary(
             attrs.storage_epoch,
             @incarnation_id_size,
             :invalid_storage_epoch
           ),
         :ok <- positive_database_int(attrs.required_generation, :invalid_required_generation),
         :ok <-
           fixed_binary(
             attrs.required_manifest_hash,
             @hash_size,
             :invalid_required_manifest_hash
           ),
         :ok <- u32(attrs.command_epoch, :invalid_command_epoch),
         :ok <- positive_database_int(attrs.command_sequence, :invalid_command_sequence),
         {:ok, command_id} <- Command.normalize_uuid(attrs.command_id, :invalid_command_id) do
      {:ok,
       %{
         device_id: device_id,
         credential_epoch: attrs.credential_epoch,
         storage_epoch: attrs.storage_epoch,
         required_generation: attrs.required_generation,
         required_manifest_hash: attrs.required_manifest_hash,
         command_epoch: attrs.command_epoch,
         command_sequence: attrs.command_sequence,
         command_id: command_id
       }}
    end
  end

  defp encode_command_fence(fence) do
    <<fence.device_id::binary-size(@device_id_size), fence.credential_epoch::32,
      fence.storage_epoch::binary-size(@incarnation_id_size), fence.required_generation::64,
      fence.required_manifest_hash::binary-size(@hash_size), fence.command_epoch::32, fence.command_sequence::64,
      fence.command_id::binary-size(@device_id_size)>>
  end

  defp command_status_code(status) when is_atom(status) do
    case Contract.command_status(status) do
      {:ok, code} when is_integer(code) -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end

  defp command_status_code(_status), do: {:error, :unknown_command_status}

  defp command_reason_code(reason) when is_atom(reason) do
    case Contract.command_reason(reason) do
      {:ok, code} when is_integer(code) -> {:ok, code}
      {:error, _reason} = error -> error
    end
  end

  defp command_reason_code(_reason), do: {:error, :unknown_command_reason}

  # Shared identity and compatibility encodings

  defp encode_identity(attrs) do
    with :ok <- fixed_binary(Map.get(attrs, :device_id), @device_id_size, :invalid_device_id),
         :ok <- u32(Map.get(attrs, :credential_epoch), :invalid_credential_epoch),
         :ok <-
           nonzero_binary(Map.get(attrs, :boot_id), @incarnation_id_size, :invalid_boot_id),
         :ok <-
           nonzero_binary(
             Map.get(attrs, :storage_epoch),
             @incarnation_id_size,
             :invalid_storage_epoch
           ) do
      {:ok,
       <<attrs.device_id::binary-size(@device_id_size), attrs.credential_epoch::32,
         attrs.boot_id::binary-size(@incarnation_id_size), attrs.storage_epoch::binary-size(@incarnation_id_size)>>}
    end
  end

  defp take_identity(
         <<device_id::binary-size(@device_id_size), credential_epoch::32, boot_id::binary-size(@incarnation_id_size),
           storage_epoch::binary-size(@incarnation_id_size), rest::binary>>
       ) do
    identity = %{
      device_id: device_id,
      credential_epoch: credential_epoch,
      boot_id: boot_id,
      storage_epoch: storage_epoch
    }

    with {:ok, _encoded} <- encode_identity(identity), do: {:ok, identity, rest}
  end

  defp take_identity(_), do: {:error, :truncated}

  defp encode_effective_identity(nil), do: {:ok, <<0>>}

  defp encode_effective_identity(effective) when is_map(effective) do
    expected = [:credential_epoch, :generation, :manifest_hash]

    with :ok <- exact_keys(effective, expected, :invalid_effective_identity),
         :ok <- u32(effective.credential_epoch, :invalid_credential_epoch),
         :ok <- positive_database_int(effective.generation, :invalid_generation),
         :ok <- fixed_binary(effective.manifest_hash, @hash_size, :invalid_manifest_hash) do
      {:ok,
       <<1, effective.credential_epoch::32, effective.generation::64, effective.manifest_hash::binary-size(@hash_size)>>}
    end
  end

  defp encode_effective_identity(_), do: {:error, :invalid_effective_identity}

  defp take_effective_identity(<<0, rest::binary>>), do: {:ok, nil, rest}

  defp take_effective_identity(
         <<1, credential_epoch::32, generation::64, manifest_hash::binary-size(@hash_size), rest::binary>>
       ) do
    effective = %{
      credential_epoch: credential_epoch,
      generation: generation,
      manifest_hash: manifest_hash
    }

    with {:ok, _encoded} <- encode_effective_identity(effective), do: {:ok, effective, rest}
  end

  defp take_effective_identity(<<_presence, _rest::binary>>),
    do: {:error, :invalid_effective_presence}

  defp take_effective_identity(_), do: {:error, :truncated}

  defp encode_firmware_version(value) when is_binary(value) do
    cond do
      byte_size(value) == 0 or byte_size(value) > @max_firmware_size ->
        {:error, :invalid_firmware_version}

      not String.valid?(value) or String.normalize(value, :nfc) != value ->
        {:error, :invalid_firmware_version}

      String.contains?(value, "+") ->
        {:error, :invalid_firmware_version}

      true ->
        case Version.parse(value) do
          {:ok, version} ->
            if to_string(version) == value,
              do: {:ok, <<byte_size(value)::16, value::binary>>},
              else: {:error, :invalid_firmware_version}

          :error ->
            {:error, :invalid_firmware_version}
        end
    end
  end

  defp encode_firmware_version(_), do: {:error, :invalid_firmware_version}

  defp encode_git_sha(value) when is_binary(value) do
    if byte_size(value) >= 7 and byte_size(value) <= @max_git_sha_size and
         Regex.match?(~r/\A[0-9a-f]+\z/, value) do
      {:ok, <<byte_size(value)::16, value::binary>>}
    else
      {:error, :invalid_git_sha}
    end
  end

  defp encode_git_sha(_), do: {:error, :invalid_git_sha}

  defp encode_capabilities(capabilities) when is_list(capabilities) do
    with :ok <- ensure_proper_list(capabilities, :invalid_capabilities),
         :ok <-
           ensure(length(capabilities) <= Contract.max_capabilities(), :too_many_capabilities),
         {:ok, normalized} <- normalize_capabilities(capabilities),
         :ok <- validate_capability_order(normalized) do
      encoded = Enum.map(normalized, &<<&1.id::16, &1.version::16>>)
      {:ok, IO.iodata_to_binary([<<length(normalized)::16>>, encoded])}
    end
  end

  defp encode_capabilities(_), do: {:error, :invalid_capabilities}

  defp take_capabilities(<<count::16, rest::binary>>) do
    with :ok <- ensure(count <= Contract.max_capabilities(), :too_many_capabilities),
         {:ok, capabilities, trailing} <- take_capability_entries(rest, count, []),
         {:ok, _encoded} <- encode_capabilities(capabilities) do
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
          {:ok, id, expected} when expected == version ->
            {:cont, {:ok, [%{id: id, version: version} | acc]}}

          {:ok, _id, _expected} ->
            {:halt, {:error, :unsupported_capability_version}}

          {:error, _reason} ->
            {:halt, {:error, :unknown_capability}}
        end

      _, _acc ->
        {:halt, {:error, :invalid_capabilities}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp validate_capability_order(capabilities) do
    ids = Enum.map(capabilities, & &1.id)

    cond do
      length(ids) != length(Enum.uniq(ids)) -> {:error, :duplicate_capability}
      ids != Enum.sort(ids) -> {:error, :capabilities_out_of_order}
      true -> :ok
    end
  end

  # Chunk and resume helpers

  defp validate_chunk_geometry(attrs) do
    with :ok <- positive_u64(attrs.total_content_length, :invalid_total_content_length),
         :ok <-
           ensure(
             attrs.total_content_length <= Contract.max_section_size(),
             :section_too_large
           ),
         :ok <- u32(attrs.chunk_index, :invalid_chunk_index),
         :ok <- u32(attrs.chunk_count, :invalid_chunk_count),
         :ok <- u64(attrs.chunk_offset, :invalid_chunk_offset),
         :ok <- ensure(is_binary(attrs.chunk), :invalid_chunk),
         expected_count = chunk_count(attrs.total_content_length),
         :ok <- ensure(attrs.chunk_count == expected_count, :invalid_chunk_count),
         :ok <- ensure(attrs.chunk_index < attrs.chunk_count, :invalid_chunk_index),
         expected_offset = attrs.chunk_index * Contract.chunk_size(),
         :ok <- ensure(attrs.chunk_offset == expected_offset, :invalid_chunk_offset),
         expected_length =
           min(Contract.chunk_size(), attrs.total_content_length - attrs.chunk_offset),
         :ok <- ensure(byte_size(attrs.chunk) == expected_length, :invalid_chunk_length) do
      :ok
    end
  end

  defp chunk_count(total), do: div(total + Contract.chunk_size() - 1, Contract.chunk_size())

  defp encode_incomplete_sections(sections) when is_list(sections) do
    with :ok <- ensure_proper_list(sections, :invalid_incomplete_sections),
         :ok <- ensure(length(sections) <= length(Contract.sections()), :too_many_sections),
         {:ok, normalized} <- normalize_incomplete_sections(sections),
         :ok <- validate_incomplete_order(normalized),
         total_ranges <- Enum.reduce(normalized, 0, &(length(&1.ranges) + &2)),
         :ok <- ensure(total_ranges <= Contract.max_missing_ranges(), :too_many_missing_ranges) do
      encoded =
        Enum.map(normalized, fn entry ->
          ranges = Enum.map(entry.ranges, &<<&1.first_chunk_index::32, &1.chunk_count::32>>)

          [
            <<entry.code, entry.section_schema_version::16, entry.section_hash::binary-size(@hash_size),
              entry.total_content_length::64, length(entry.ranges)::16>>,
            ranges
          ]
        end)

      {:ok, IO.iodata_to_binary(encoded)}
    end
  end

  defp encode_incomplete_sections(_), do: {:error, :invalid_incomplete_sections}

  defp normalize_incomplete_sections(sections) do
    sections
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_incomplete_section(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_incomplete_section(entry) when is_map(entry) do
    expected = [
      :section,
      :section_schema_version,
      :section_hash,
      :total_content_length,
      :missing_ranges
    ]

    with :ok <- exact_keys(entry, expected, :invalid_incomplete_section),
         {:ok, code} <- section_identity(entry.section, entry.section_schema_version),
         :ok <- fixed_binary(entry.section_hash, @hash_size, :invalid_section_hash),
         :ok <- positive_u64(entry.total_content_length, :invalid_total_content_length),
         :ok <-
           ensure(entry.total_content_length <= Contract.max_section_size(), :section_too_large),
         {:ok, ranges} <-
           validate_missing_ranges(entry.missing_ranges, entry.total_content_length) do
      {:ok,
       Map.merge(entry, %{
         code: code,
         ranges: ranges
       })}
    end
  end

  defp normalize_incomplete_section(_), do: {:error, :invalid_incomplete_section}

  defp validate_missing_ranges(ranges, total_content_length) when is_list(ranges) do
    with :ok <- ensure_proper_list(ranges, :invalid_missing_ranges),
         :ok <- ensure(ranges != [], :invalid_missing_ranges),
         :ok <-
           ensure(
             length(ranges) <= Contract.max_missing_ranges_per_section(),
             :too_many_missing_ranges
           ),
         total_chunks = chunk_count(total_content_length),
         {:ok, normalized} <- normalize_missing_ranges(ranges, total_chunks),
         :ok <- validate_minimal_ranges(normalized) do
      {:ok, normalized}
    end
  end

  defp validate_missing_ranges(_ranges, _total_content_length),
    do: {:error, :invalid_missing_ranges}

  defp normalize_missing_ranges(ranges, total_chunks) do
    ranges
    |> Enum.reduce_while({:ok, []}, fn range, {:ok, acc} ->
      expected = [:first_chunk_index, :chunk_count]

      with true <- is_map(range) || {:error, :invalid_missing_range},
           :ok <- exact_keys(range, expected, :invalid_missing_range),
           :ok <- u32(range.first_chunk_index, :invalid_missing_range),
           :ok <- positive_u32(range.chunk_count, :invalid_missing_range),
           :ok <-
             ensure(
               range.first_chunk_index + range.chunk_count <= total_chunks,
               :invalid_missing_range
             ) do
        {:cont, {:ok, [range | acc]}}
      else
        false -> {:halt, {:error, :invalid_missing_range}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp validate_minimal_ranges([first | rest]), do: validate_minimal_ranges(rest, first)
  defp validate_minimal_ranges([]), do: :ok

  defp validate_minimal_ranges([current | rest], previous) do
    previous_end = previous.first_chunk_index + previous.chunk_count

    if current.first_chunk_index > previous_end do
      validate_minimal_ranges(rest, current)
    else
      {:error, :nonminimal_missing_ranges}
    end
  end

  defp validate_minimal_ranges([], _previous), do: :ok

  defp validate_incomplete_order(normalized) do
    codes = Enum.map(normalized, & &1.code)

    cond do
      length(codes) != length(Enum.uniq(codes)) -> {:error, :duplicate_section}
      codes != Enum.sort(codes) -> {:error, :sections_out_of_order}
      true -> :ok
    end
  end

  defp take_incomplete_sections(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_incomplete_sections(
         <<code, schema_version::16, section_hash::binary-size(@hash_size), total_content_length::64, range_count::16,
           rest::binary>>,
         count,
         acc
       ) do
    with section when is_atom(section) <- Contract.section_name(code),
         {:ok, missing_ranges, trailing} <- take_missing_ranges(rest, range_count, []),
         entry = %{
           section: section,
           section_schema_version: schema_version,
           section_hash: section_hash,
           total_content_length: total_content_length,
           missing_ranges: missing_ranges
         } do
      take_incomplete_sections(trailing, count - 1, [entry | acc])
    else
      {:error, _reason} = error -> error
      _ -> {:error, :unknown_section}
    end
  end

  defp take_incomplete_sections(_rest, _count, _acc), do: {:error, :truncated}

  defp take_missing_ranges(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_missing_ranges(<<first::32, count::32, rest::binary>>, remaining, acc) do
    take_missing_ranges(rest, remaining - 1, [
      %{first_chunk_index: first, chunk_count: count} | acc
    ])
  end

  defp take_missing_ranges(_rest, _remaining, _acc), do: {:error, :truncated}

  # ACK section helpers

  defp encode_section_summaries(sections) when is_list(sections) do
    with :ok <- ensure_proper_list(sections, :invalid_sections),
         :ok <- validate_complete_summary_names(sections) do
      sections
      |> Enum.reduce_while({:ok, []}, fn summary, {:ok, acc} ->
        case encode_section_summary(summary) do
          {:ok, bytes} -> {:cont, {:ok, [bytes | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, encoded} -> {:ok, encoded |> Enum.reverse() |> IO.iodata_to_binary()}
        error -> error
      end
    end
  end

  defp encode_section_summaries(_), do: {:error, :invalid_sections}

  defp encode_section_summary(summary) when is_map(summary) do
    expected = [:section, :section_schema_version, :tombstone, :section_hash]

    with :ok <- exact_keys(summary, expected, :invalid_section_summary),
         {:ok, code} <- section_identity(summary.section, summary.section_schema_version),
         :ok <- ensure(is_boolean(summary.tombstone), :invalid_tombstone),
         :ok <-
           ensure(
             not summary.tombstone or Contract.tombstone_allowed?(summary.section),
             :tombstone_not_allowed
           ),
         :ok <- fixed_binary(summary.section_hash, @hash_size, :invalid_section_hash) do
      tombstone = if summary.tombstone, do: 1, else: 0

      {:ok, <<code, summary.section_schema_version::16, tombstone, summary.section_hash::binary-size(@hash_size)>>}
    end
  end

  defp encode_section_summary(_), do: {:error, :invalid_section_summary}

  defp validate_complete_summary_names(sections) do
    names = Enum.map(sections, &Map.get(&1, :section))
    expected = Contract.sections()

    cond do
      Enum.any?(names, &(&1 not in expected)) -> {:error, :unknown_section}
      length(Enum.uniq(names)) != length(names) -> {:error, :duplicate_section}
      length(names) < length(expected) -> {:error, :missing_section}
      length(names) > length(expected) -> {:error, :duplicate_section}
      names != expected -> {:error, :sections_out_of_order}
      true -> :ok
    end
  end

  defp take_section_summaries(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_section_summaries(
         <<code, schema_version::16, tombstone_code, section_hash::binary-size(@hash_size), rest::binary>>,
         count,
         acc
       ) do
    with section when is_atom(section) <- Contract.section_name(code),
         {:ok, tombstone} <- decode_boolean(tombstone_code) do
      summary = %{
        section: section,
        section_schema_version: schema_version,
        tombstone: tombstone,
        section_hash: section_hash
      }

      take_section_summaries(rest, count - 1, [summary | acc])
    else
      {:error, _reason} = error -> error
      _ -> {:error, :unknown_section}
    end
  end

  defp take_section_summaries(_rest, _count, _acc), do: {:error, :truncated}

  defp encode_rejection_section(nil), do: {:ok, <<0>>}

  defp encode_rejection_section(section) when is_map(section) do
    expected = [:section, :section_schema_version, :section_hash]

    with :ok <- exact_keys(section, expected, :invalid_rejection_shape),
         {:ok, code} <- section_identity(section.section, section.section_schema_version),
         :ok <- fixed_binary(section.section_hash, @hash_size, :invalid_section_hash) do
      {:ok, <<1, code, section.section_schema_version::16, section.section_hash::binary-size(@hash_size)>>}
    end
  end

  defp encode_rejection_section(_), do: {:error, :invalid_rejection_shape}

  defp take_rejection_section(<<0, rest::binary>>), do: {:ok, nil, rest}

  defp take_rejection_section(<<1, code, schema_version::16, section_hash::binary-size(@hash_size), rest::binary>>) do
    case Contract.section_name(code) do
      section when is_atom(section) ->
        {:ok,
         %{
           section: section,
           section_schema_version: schema_version,
           section_hash: section_hash
         }, rest}

      {:error, _reason} = error ->
        error
    end
  end

  defp take_rejection_section(<<_presence, _rest::binary>>),
    do: {:error, :invalid_rejection_shape}

  defp take_rejection_section(_), do: {:error, :truncated}

  # Validation and framing helpers

  defp validate_generation_hash(attrs) do
    with :ok <- positive_database_int(Map.get(attrs, :generation), :invalid_generation),
         :ok <- fixed_binary(Map.get(attrs, :manifest_hash), @hash_size, :invalid_manifest_hash) do
      :ok
    end
  end

  defp validate_manifest_binding(attrs, manifest) do
    if manifest.device_id == attrs.device_id and
         manifest.credential_epoch == attrs.credential_epoch and
         manifest.generation == attrs.generation do
      :ok
    else
      {:error, :manifest_binding_mismatch}
    end
  end

  defp manifest_size(value) when is_binary(value) do
    if byte_size(value) <= Contract.max_manifest_size(),
      do: :ok,
      else: {:error, :manifest_too_large}
  end

  defp manifest_size(_), do: {:error, :invalid_manifest}

  defp section_identity(section, schema_version) do
    case Contract.section_code(section) do
      code when is_integer(code) ->
        if Contract.section_schema_version(section) == schema_version,
          do: {:ok, code},
          else: {:error, :unsupported_section_schema}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_secret(secret) when is_binary(secret) do
    if byte_size(secret) <= Contract.max_secret_size(), do: :ok, else: {:error, :secret_too_large}
  end

  defp validate_secret(_), do: {:error, :invalid_secret}

  defp strip_header(type, bytes) do
    with {:ok, expected_code, _direction} <- Contract.message_type(type) do
      domain = Contract.payload_domain(type)
      size = byte_size(domain)

      case bytes do
        <<presented::binary-size(size), version, actual_code, rest::binary>> ->
          cond do
            presented != domain -> {:error, :payload_domain_mismatch}
            version != Contract.version() -> {:error, :unsupported_payload_version}
            actual_code != expected_code -> {:error, :payload_type_mismatch}
            true -> {:ok, rest}
          end

        _ ->
          {:error, :truncated}
      end
    end
  end

  defp take_lp(<<length::16, rest::binary>>) when byte_size(rest) >= length do
    <<value::binary-size(length), trailing::binary>> = rest
    {:ok, value, trailing}
  end

  defp take_lp(_), do: {:error, :truncated}

  defp exact_keys(attrs, expected, error) when is_map(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected), do: :ok, else: {:error, error}
  end

  defp exact_keys(_attrs, _expected, error), do: {:error, error}

  defp fixed_binary(value, size, _error) when is_binary(value) and byte_size(value) == size,
    do: :ok

  defp fixed_binary(_value, _size, error), do: {:error, error}

  defp nonzero_binary(value, size, error) do
    with :ok <- fixed_binary(value, size, error),
         :ok <- ensure(value != :binary.copy(<<0>>, size), error) do
      :ok
    end
  end

  defp selected_version(1), do: :ok
  defp selected_version(_), do: {:error, :unsupported_selected_version}

  defp u32(value, _error) when is_integer(value) and value >= 0 and value <= @u32_max, do: :ok
  defp u32(_value, error), do: {:error, error}

  defp positive_u32(value, _error)
       when is_integer(value) and value > 0 and value <= @u32_max,
       do: :ok

  defp positive_u32(_value, error), do: {:error, error}

  defp u64(value, _error) when is_integer(value) and value >= 0 and value <= @u64_max, do: :ok
  defp u64(_value, error), do: {:error, error}

  defp positive_u64(value, _error)
       when is_integer(value) and value > 0 and value <= @u64_max,
       do: :ok

  defp positive_u64(_value, error), do: {:error, error}

  defp positive_database_int(value, _error)
       when is_integer(value) and value > 0 and value <= @database_int_max,
       do: :ok

  defp positive_database_int(_value, error), do: {:error, error}

  defp database_int(value, _error)
       when is_integer(value) and value >= 0 and value <= @database_int_max,
       do: :ok

  defp database_int(_value, error), do: {:error, error}

  defp decode_boolean(0), do: {:ok, false}
  defp decode_boolean(1), do: {:ok, true}
  defp decode_boolean(_), do: {:error, :invalid_boolean}

  defp ensure_proper_list([], _error), do: :ok
  defp ensure_proper_list([_ | rest], error), do: ensure_proper_list(rest, error)
  defp ensure_proper_list(_value, error), do: {:error, error}

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}

  defp secure_equal(left, right) do
    is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) and
      :crypto.hash_equals(left, right)
  end
end
