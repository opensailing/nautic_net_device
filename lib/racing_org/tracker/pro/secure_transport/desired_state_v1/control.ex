defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Control do
  @moduledoc """
  Pure `control_v1` key derivation, state, AEAD framing, replay defense, and carrier codec.

  Control counters and replay windows are independent from the established secure-
  transport session's data-plane state. The complete 40-byte `ROC1` header is AEAD AAD;
  the nonce is `credential_epoch:u32 || counter:u64`.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport, as: SecureTransport
  alias RacingOrg.Tracker.Pro.SecureTransport.{Handshake, Primitives, ReplayWindow, Session}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @magic "ROC1"
  @header_size 40
  @tag_size 16
  @session_id_size 16
  @u32_max 0xFFFF_FFFF

  @enforce_keys [
    :role,
    :session_id,
    :credential_epoch,
    :send_key,
    :receive_key,
    :send_direction,
    :receive_direction,
    :replay_window
  ]
  @derive {Inspect, except: [:send_key, :receive_key]}
  defstruct [
    :role,
    :session_id,
    :credential_epoch,
    :send_key,
    :receive_key,
    :send_direction,
    :receive_direction,
    send_counter: 0,
    replay_window: nil
  ]

  @type endpoint_role :: :server | :device
  @type direction :: :device_to_server | :server_to_device

  @type t :: %__MODULE__{
          role: endpoint_role(),
          session_id: binary(),
          credential_epoch: non_neg_integer(),
          send_key: binary(),
          receive_key: binary(),
          send_direction: direction(),
          receive_direction: direction(),
          send_counter: non_neg_integer(),
          replay_window: ReplayWindow.t()
        }

  @doc "Derive the two purpose-0x81 directional keys from an established session."
  @spec derive_keys(Session.t()) :: {:ok, map()} | {:error, atom()}
  def derive_keys(%Session{} = session) do
    with {:ok, device_to_server} <-
           Handshake.derive_purpose_key(
             session,
             Contract.purpose_control_v1(),
             SecureTransport.dir_device_to_server()
           ),
         {:ok, server_to_device} <-
           Handshake.derive_purpose_key(
             session,
             Contract.purpose_control_v1(),
             SecureTransport.dir_server_to_device()
           ) do
      {:ok,
       %{
         device_to_server: device_to_server,
         server_to_device: server_to_device
       }}
    end
  end

  def derive_keys(_session), do: {:error, :invalid_session}

  @doc "Create independent control state for one endpoint role."
  @spec new(endpoint_role(), Session.t()) :: {:ok, t()} | {:error, atom()}
  def new(role, %Session{} = session) when role in [:server, :device] do
    with :ok <- fixed_binary(session.session_id, @session_id_size, :invalid_session_id),
         :ok <- credential_epoch(session.credential_epoch),
         :ok <- ensure(session.epoch == session.credential_epoch, :credential_epoch_mismatch),
         {:ok, keys} <- derive_keys(session) do
      {send_key, receive_key, send_direction, receive_direction} = role_keys(role, keys)

      {:ok,
       %__MODULE__{
         role: role,
         session_id: session.session_id,
         credential_epoch: session.credential_epoch,
         send_key: send_key,
         receive_key: receive_key,
         send_direction: send_direction,
         receive_direction: receive_direction,
         send_counter: 0,
         replay_window: ReplayWindow.new()
       }}
    end
  end

  def new(role, %Session{}) when role not in [:server, :device], do: {:error, :invalid_control_role}
  def new(_role, _session), do: {:error, :invalid_session}

  @doc "Seal one registered control payload and advance only the control send counter."
  @spec seal(t(), atom(), binary()) :: {:ok, binary(), t()} | {:error, atom()}
  def seal(%__MODULE__{} = state, type, payload) when is_atom(type) and is_binary(payload) do
    with {:ok, _code, expected_direction} <- Contract.message_type(type),
         :ok <- ensure(expected_direction == state.send_direction, :wrong_message_direction),
         {:ok, frame} <-
           seal_with(
             state.send_key,
             state.session_id,
             state.credential_epoch,
             state.send_direction,
             type,
             state.send_counter,
             payload
           ) do
      {:ok, frame, %{state | send_counter: state.send_counter + 1}}
    end
  end

  def seal(%__MODULE__{}, type, _payload) when is_atom(type) do
    case Contract.message_type(type) do
      {:ok, _code, _direction} -> {:error, :invalid_payload}
      {:error, _reason} = error -> error
    end
  end

  def seal(%__MODULE__{}, _type, _payload), do: {:error, :unsupported_message_type}
  def seal(_state, _type, _payload), do: {:error, :invalid_control_state}

  @doc "Statelessly seal with explicit key, identity, direction, type, and counter."
  @spec seal_with(
          binary(),
          binary(),
          non_neg_integer(),
          direction(),
          atom(),
          non_neg_integer(),
          binary(),
          keyword()
        ) :: {:ok, binary()} | {:error, atom()}
  def seal_with(key, session_id, credential_epoch, direction, type, counter, payload, opts \\ [])

  def seal_with(key, session_id, credential_epoch, direction, type, counter, payload, opts)
      when is_atom(type) and is_binary(payload) and is_list(opts) do
    with :ok <- fixed_binary(key, SecureTransport.key_size(), :bad_key_length),
         :ok <- fixed_binary(session_id, @session_id_size, :invalid_session_id),
         :ok <- credential_epoch(credential_epoch),
         :ok <- send_counter(counter),
         :ok <- plaintext_size(payload),
         {:ok, type_code, expected_direction} <- Contract.message_type(type),
         :ok <- ensure(direction == expected_direction, :wrong_message_direction),
         {:ok, direction_code} <- encode_direction(direction),
         :ok <- maybe_validate_payload(type, type_code, payload, opts) do
      header =
        encode_header(
          direction_code,
          type_code,
          session_id,
          credential_epoch,
          counter,
          byte_size(payload)
        )

      nonce = <<credential_epoch::32, counter::64>>

      with {:ok, ciphertext, tag} <- Primitives.aead_seal(key, nonce, payload, header) do
        {:ok, <<header::binary, ciphertext::binary, tag::binary>>}
      end
    end
  end

  def seal_with(_key, _session_id, _epoch, _direction, type, _counter, _payload, _opts)
      when is_atom(type) do
    case Contract.message_type(type) do
      {:ok, _code, _direction} -> {:error, :invalid_control_frame_input}
      {:error, _reason} = error -> error
    end
  end

  def seal_with(_key, _session_id, _epoch, _direction, _type, _counter, _payload, _opts),
    do: {:error, :unsupported_message_type}

  @doc "Open one control frame, authenticate it, and update only the control replay window."
  @spec open(t(), binary()) ::
          {:ok, atom(), binary(), t()}
          | {:error, atom()}
          | {:error, atom(), t()}
  def open(%__MODULE__{} = state, frame) when is_binary(frame) do
    with {:ok, header, ciphertext, tag} <- split_frame(frame),
         {:ok, parsed} <- parse_header(header),
         :ok <- ensure(parsed.direction == state.receive_direction, :wrong_direction),
         :ok <-
           ensure(
             Primitives.secure_compare(parsed.session_id, state.session_id),
             :wrong_session
           ),
         :ok <-
           ensure(
             parsed.credential_epoch == state.credential_epoch,
             :stale_credential_epoch
           ),
         :ok <- ensure(parsed.ciphertext_length == byte_size(ciphertext), :invalid_frame_length),
         :ok <- send_counter(parsed.counter),
         :ok <- ReplayWindow.check(state.replay_window, parsed.counter),
         nonce = <<parsed.credential_epoch::32, parsed.counter::64>>,
         {:ok, payload} <-
           Primitives.aead_open(state.receive_key, nonce, ciphertext, header, tag),
         {:ok, replay_window} <-
           ReplayWindow.check_and_commit(state.replay_window, parsed.counter) do
      next_state = %{state | replay_window: replay_window}

      case validate_payload_header(parsed.type, parsed.type_code, payload) do
        :ok -> {:ok, parsed.type, payload, next_state}
        {:error, reason} -> {:error, reason, next_state}
      end
    end
  end

  def open(%__MODULE__{}, _frame), do: {:error, :invalid_control_frame}
  def open(_state, _frame), do: {:error, :invalid_control_state}

  @doc "Encode exactly one strict standard-Base64 Phoenix carrier field."
  @spec encode_carrier(binary()) :: %{required(String.t()) => String.t()}
  def encode_carrier(frame) when is_binary(frame), do: %{"frame" => Base.encode64(frame)}

  @doc "Decode exactly one strict padded standard-Base64 Phoenix carrier field."
  @spec decode_carrier(map()) :: {:ok, binary()} | {:error, atom()}
  def decode_carrier(%{"frame" => encoded} = carrier)
      when map_size(carrier) == 1 and is_binary(encoded) do
    with {:ok, frame} <- Base.decode64(encoded, padding: true),
         :ok <- ensure(Base.encode64(frame) == encoded, :invalid_control_base64) do
      {:ok, frame}
    else
      :error -> {:error, :invalid_control_base64}
      {:error, _reason} = error -> error
    end
  end

  def decode_carrier(_carrier), do: {:error, :invalid_control_carrier}

  @doc "Maximum control plaintext length before AEAD."
  @spec max_plaintext_size() :: pos_integer()
  def max_plaintext_size, do: Contract.max_plaintext_size()

  @doc "Frozen control frame header size."
  @spec header_size() :: pos_integer()
  def header_size, do: @header_size

  defp parse_header(
         <<@magic, control_version, aead_id, direction_code, type_code, session_id::binary-size(@session_id_size),
           credential_epoch::32, counter::64, ciphertext_length::32>>
       ) do
    with :ok <- ensure(control_version == Contract.version(), :unsupported_control_version),
         :ok <-
           ensure(
             aead_id == SecureTransport.aead_chacha20_poly1305(),
             :unsupported_control_aead
           ),
         {:ok, direction} <- decode_direction(direction_code),
         {:ok, type, expected_direction} <- Contract.message_type(type_code),
         :ok <- ensure(direction == expected_direction, :wrong_message_direction),
         :ok <- ensure(ciphertext_length <= max_plaintext_size(), :plaintext_too_large) do
      {:ok,
       %{
         direction: direction,
         direction_code: direction_code,
         type: type,
         type_code: type_code,
         session_id: session_id,
         credential_epoch: credential_epoch,
         counter: counter,
         ciphertext_length: ciphertext_length
       }}
    end
  end

  defp parse_header(<<_::binary-size(@header_size)>>), do: {:error, :invalid_control_header}
  defp parse_header(_header), do: {:error, :invalid_control_header}

  defp split_frame(frame) when byte_size(frame) >= @header_size + @tag_size do
    ciphertext_length = byte_size(frame) - @header_size - @tag_size

    <<header::binary-size(@header_size), ciphertext::binary-size(ciphertext_length), tag::binary-size(@tag_size)>> =
      frame

    case header do
      <<_::binary-size(36), declared_length::32>> when declared_length == ciphertext_length ->
        {:ok, header, ciphertext, tag}

      <<_::binary-size(36), _declared_length::32>> ->
        {:error, :invalid_frame_length}
    end
  end

  defp split_frame(_frame), do: {:error, :invalid_frame_length}

  defp encode_header(
         direction_code,
         type_code,
         <<session_id::binary-size(@session_id_size)>>,
         credential_epoch,
         counter,
         ciphertext_length
       ) do
    <<@magic, Contract.version(), SecureTransport.aead_chacha20_poly1305(), direction_code, type_code,
      session_id::binary, credential_epoch::32, counter::64, ciphertext_length::32>>
  end

  defp validate_payload_header(type, expected_type_code, payload) do
    domain = Contract.payload_domain(type)
    domain_size = byte_size(domain)

    case payload do
      <<presented_domain::binary-size(domain_size), version, type_code, _rest::binary>> ->
        cond do
          presented_domain != domain -> {:error, :payload_domain_mismatch}
          version != Contract.version() -> {:error, :unsupported_payload_version}
          type_code != expected_type_code -> {:error, :payload_type_mismatch}
          true -> :ok
        end

      _ ->
        {:error, :truncated}
    end
  end

  defp maybe_validate_payload(type, type_code, payload, opts) do
    case Keyword.get(opts, :validate_payload_domain, true) do
      true -> validate_payload_header(type, type_code, payload)
      false -> :ok
      _other -> {:error, :invalid_control_options}
    end
  end

  defp role_keys(:server, keys) do
    {keys.server_to_device, keys.device_to_server, :server_to_device, :device_to_server}
  end

  defp role_keys(:device, keys) do
    {keys.device_to_server, keys.server_to_device, :device_to_server, :server_to_device}
  end

  defp encode_direction(:device_to_server),
    do: {:ok, SecureTransport.dir_device_to_server()}

  defp encode_direction(:server_to_device),
    do: {:ok, SecureTransport.dir_server_to_device()}

  defp encode_direction(_direction), do: {:error, :unsupported_direction}

  defp decode_direction(code) do
    cond do
      code == SecureTransport.dir_device_to_server() -> {:ok, :device_to_server}
      code == SecureTransport.dir_server_to_device() -> {:ok, :server_to_device}
      true -> {:error, :unsupported_direction}
    end
  end

  defp credential_epoch(value) when is_integer(value) and value >= 0 and value <= @u32_max,
    do: :ok

  defp credential_epoch(_value), do: {:error, :invalid_credential_epoch}

  defp send_counter(value) when is_integer(value) and value >= 0 do
    cond do
      value >= SecureTransport.counter_max() -> {:error, :counter_exhausted}
      value >= SecureTransport.rekey_after() -> {:error, :rekey_required}
      true -> :ok
    end
  end

  defp send_counter(_value), do: {:error, :invalid_counter}

  defp plaintext_size(payload) do
    if byte_size(payload) <= max_plaintext_size(),
      do: :ok,
      else: {:error, :plaintext_too_large}
  end

  defp fixed_binary(value, size, _reason)
       when is_binary(value) and byte_size(value) == size,
       do: :ok

  defp fixed_binary(_value, _size, reason), do: {:error, reason}

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: {:error, reason}
end
