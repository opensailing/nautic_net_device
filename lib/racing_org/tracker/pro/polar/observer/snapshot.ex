defmodule RacingOrg.Tracker.Pro.Polar.Observer.Snapshot do
  @moduledoc """
  Canonical call-time checkpoint boundary for the sailed-polar observer.

  A snapshot is a deliberately closed envelope around canonical polar
  checkpoint schema-v2 bytes. It binds the producing boat authority, the full
  admission-policy fingerprint, an explicit monotonic learner revision, and the
  established checkpoint-content hash. Process collaborators, persistence
  clocks, dirty flags, sync state, and other incarnation-local fields cannot
  cross this boundary.

  The runtime reconciliation ceiling is one MiB. This is intentionally larger
  than the durable transport's current single-frame limit: valid polar content
  can be reconciled locally while awaiting chunked transport integration.
  """

  alias RacingOrg.Tracker.Pro.Polar.Checkpoint, as: PolarCheckpoint
  alias RacingOrg.Tracker.Pro.Polar.Observer.Bins
  alias RacingOrg.Tracker.Pro.Polar.Observer.Gate
  alias RacingOrg.Tracker.Pro.Polar.Observer.PSquare
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Canonical

  @kind :polar
  @schema_version 2
  @max_content_size 1_048_576
  @database_int_max 9_223_372_036_854_775_807
  @policy_domain "RacingOrg-PolarObserverPolicy-v1"
  @fingerprint_domain "RacingOrg-PolarObserverSnapshot-v1"

  @fields MapSet.new([
            :authority,
            :policy_hash,
            :kind,
            :schema_version,
            :source_generation,
            :content_hash,
            :content
          ])

  @type t :: %{
          required(:authority) => String.t(),
          required(:policy_hash) => <<_::256>>,
          required(:kind) => :polar,
          required(:schema_version) => 2,
          required(:source_generation) => non_neg_integer(),
          required(:content_hash) => <<_::256>>,
          required(:content) => binary()
        }

  @type hydrated :: %{
          authority: String.t(),
          policy_hash: <<_::256>>,
          bins: Bins.t(),
          p: float(),
          cells: %{optional(Bins.key()) => {pos_integer(), PSquare.t()}},
          fingerprint: <<_::256>>,
          source_generation: non_neg_integer(),
          content_hash: <<_::256>>
        }

  @type error_reason ::
          :invalid_checkpoint
          | :checkpoint_too_large
          | :checkpoint_content_hash_mismatch

  @doc "Build one canonical snapshot from the exact state owned by the caller."
  @spec capture(String.t(), <<_::256>>, Bins.t(), float(), non_neg_integer(), map()) ::
          {:ok, t()} | {:error, error_reason()}
  def capture(authority, policy_hash, %Bins{} = bins, p, source_generation, cells) do
    with :ok <- validate_authority(authority),
         :ok <- validate_hash(policy_hash),
         :ok <- validate_generation(source_generation),
         {:ok, content} <- PolarCheckpoint.project(bins, p, cells),
         {:ok, bytes} <- Canonical.encode(content),
         :ok <- content_size(bytes) do
      {:ok,
       %{
         authority: authority,
         policy_hash: policy_hash,
         kind: @kind,
         schema_version: @schema_version,
         source_generation: source_generation,
         content_hash: content_hash(bytes),
         content: bytes
       }}
    else
      {:error, :checkpoint_too_large} = error -> error
      _error -> {:error, :invalid_checkpoint}
    end
  end

  def capture(_authority, _policy_hash, _bins, _p, _source_generation, _cells),
    do: {:error, :invalid_checkpoint}

  @doc "Validate, authenticate by canonical content hash, and hydrate a snapshot."
  @spec hydrate(term()) :: {:ok, hydrated()} | {:error, error_reason()}
  def hydrate(snapshot) do
    with :ok <- envelope(snapshot),
         :ok <- content_size(snapshot.content),
         :ok <- verify_content_hash(snapshot.content, snapshot.content_hash),
         {:ok, content} <- Canonical.decode(snapshot.content),
         {:ok, canonical} <- Canonical.encode(content),
         true <- canonical == snapshot.content,
         {:ok, runtime} <- PolarCheckpoint.hydrate(content) do
      {:ok,
       Map.merge(runtime, %{
         authority: snapshot.authority,
         policy_hash: snapshot.policy_hash,
         fingerprint: fingerprint(snapshot),
         source_generation: snapshot.source_generation,
         content_hash: snapshot.content_hash
       })}
    else
      {:error, :checkpoint_too_large} = error -> error
      {:error, :checkpoint_content_hash_mismatch} = error -> error
      _error -> {:error, :invalid_checkpoint}
    end
  end

  @doc "Fingerprint the complete canonical restore identity, including authority and revision."
  @spec fingerprint(t()) :: <<_::256>>
  def fingerprint(snapshot) do
    :crypto.hash(
      :sha256,
      @fingerprint_domain <>
        <<byte_size(snapshot.authority)::16, snapshot.authority::binary, snapshot.policy_hash::binary-size(32),
          snapshot.source_generation::64, snapshot.content_hash::binary-size(32)>>
    )
  end

  @doc "Hash the complete quantile and sample-admission policy without carrying raw runtime structs."
  @spec policy_hash(Gate.t(), number(), pos_integer(), number()) ::
          {:ok, <<_::256>>} | {:error, :invalid_checkpoint}
  def policy_hash(%Gate{} = gate, min_stw_mps, window_size, p) do
    policy = %{
      "gate" => %{
        "angle_band_deg" => Tuple.to_list(gate.angle_band_deg),
        "angle_key" => Atom.to_string(gate.angle_key),
        "engine_rpm_idle" => gate.engine_rpm_idle,
        "heel_band_deg" => Tuple.to_list(gate.heel_band_deg),
        "max_accel_mps2" => gate.max_accel_mps2,
        "max_turn_rate_dps" => gate.max_turn_rate_dps,
        "max_tws_sd_mps" => gate.max_tws_sd_mps,
        "min_dwell" => gate.min_dwell
      },
      "min_stw_mps" => min_stw_mps,
      "p" => p,
      "window_size" => window_size
    }

    with true <- is_integer(window_size) and window_size > 0,
         {:ok, bytes} <- Canonical.encode(policy) do
      {:ok, :crypto.hash(:sha256, @policy_domain <> bytes)}
    else
      _error -> {:error, :invalid_checkpoint}
    end
  rescue
    _error -> {:error, :invalid_checkpoint}
  end

  def policy_hash(_gate, _min_stw_mps, _window_size, _p),
    do: {:error, :invalid_checkpoint}

  defp envelope(snapshot) when is_map(snapshot) do
    with true <- MapSet.new(Map.keys(snapshot)) == @fields,
         :ok <- validate_authority(snapshot.authority),
         :ok <- validate_hash(snapshot.policy_hash),
         true <- snapshot.kind == @kind,
         true <- snapshot.schema_version == @schema_version,
         :ok <- validate_generation(snapshot.source_generation),
         true <- is_binary(snapshot.content),
         :ok <- validate_hash(snapshot.content_hash) do
      :ok
    else
      _error -> {:error, :invalid_checkpoint}
    end
  end

  defp envelope(_snapshot), do: {:error, :invalid_checkpoint}

  @doc false
  @spec validate_authority(term()) :: :ok | {:error, :invalid_checkpoint}
  def validate_authority(value)
      when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 65_535 do
    if String.valid?(value), do: :ok, else: {:error, :invalid_checkpoint}
  end

  def validate_authority(_value), do: {:error, :invalid_checkpoint}

  defp validate_hash(value) when is_binary(value) and byte_size(value) == 32, do: :ok
  defp validate_hash(_value), do: {:error, :invalid_checkpoint}

  defp validate_generation(value)
       when is_integer(value) and value >= 0 and value <= @database_int_max,
       do: :ok

  defp validate_generation(_value), do: {:error, :invalid_checkpoint}

  defp content_size(bytes) when byte_size(bytes) <= @max_content_size, do: :ok
  defp content_size(_bytes), do: {:error, :checkpoint_too_large}

  defp verify_content_hash(bytes, expected) do
    actual = content_hash(bytes)

    if :crypto.hash_equals(actual, expected) do
      :ok
    else
      {:error, :checkpoint_content_hash_mismatch}
    end
  end

  # This is the established DesiredStateV1 checkpoint-content hash preimage.
  # It is reproduced here because the transport helper also applies its current
  # 65,327-byte single-frame cap, while runtime reconciliation permits one MiB.
  defp content_hash(bytes) do
    {:ok, kind_code, @schema_version} = Contract.checkpoint_kind(@kind)

    :crypto.hash(
      :sha256,
      Contract.checkpoint_content_hash_domain() <>
        <<Contract.version(), kind_code, @schema_version::16, byte_size(bytes)::64, bytes::binary>>
    )
  end
end
