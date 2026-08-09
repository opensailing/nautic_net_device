defmodule RacingOrg.Tracker.Pro.WiFi.Store do
  @moduledoc """
  Durable, atomic, corruption-safe persistence of the device's DESIRED Wi-Fi
  state so a runtime change (set credentials / enable / disable) survives reboots
  WITHOUT reflashing.

  Mirrors `RacingOrg.Tracker.Pro.Commands.Store`: state is written to a temporary
  file and atomically renamed into place, so a crash mid-write cannot expose a
  partially written current file.

  `load/1` is the permissive legacy compatibility API: absent or unusable bytes
  become `:empty`. Authority-sensitive callers use `read_authority/1`, which keeps
  missing, corrupt, unrecognized, and I/O outcomes distinct. `WiFiManager` uses
  that strict API at boot and leaves `wlan0` unchanged when authority is unreadable;
  only an exactly missing marker selects the compile-time default.

  A legacy persisted state is a plain map such as:

      %{version: integer(), enabled: boolean(), ssid: String.t() | nil, psk: String.t() | nil}

  Legacy records retain their inline PSK for wire compatibility. Desired State
  records keep the credential only in the bound sidecar described below. Runtime
  VintageNet calls use `persist: false`; VintageNet does not create a second
  persisted copy of these runtime credentials.

  ## Marker / credential boundary

  There are two files, and the split is the whole point:

    * `current.wifi` — the OWNER MARKER. `save/2` and `load/1` round-trip it
      verbatim, so a LEGACY record (one that carries an inline `:psk`) still works
      exactly as it always has. A Desired State owner marker, by contrast, is
      written SECRETLESS: it has no `:psk` key at all, so the marker that is
      returned from `load/1`, echoed into desired-state journals, inspected, or
      formatted into a crash report can never carry plaintext credential material.

    * `current.wifi.credential` — the CREDENTIAL SIDECAR, reachable only through
      the credential APIs. It never merges into `load/1`. This is what preserves
      reconnect durability for a secretless marker: the device can still reassociate
      after a reboot even though its marker holds no secret.

  Every sidecar entry is BOUND to the marker it was written for (SSID +
  `desired_activation_id`). The sidecar may temporarily retain both prior and
  candidate entries across an ambiguous marker write; `credential/2` only hands back
  the exact binding requested, and `retain_credential/2` prunes losing entries once
  durable authority is known. A stale entry is therefore inert rather than silently
  applied to the wrong network.
  """

  require Logger

  alias RacingOrg.Tracker.Pro.DesiredState.AtomicFile
  alias RacingOrg.Tracker.Pro.WiFiManager.Secret

  @type state :: %{
          required(:version) => integer(),
          required(:enabled) => boolean(),
          optional(:ssid) => String.t() | nil,
          optional(:psk) => String.t() | nil,
          optional(:desired_activation_id) => binary()
        }

  @typedoc "Identifies the owner marker a sidecar credential belongs to."
  @type credential_binding :: %{
          optional(:ssid) => String.t() | nil,
          optional(:desired_activation_id) => binary() | nil
        }
  @type credential_key :: {String.t() | nil, binary() | nil}
  @type credential_entries :: %{optional(credential_key()) => binary()}

  @filename "current.wifi"
  @credential_filename "current.wifi.credential"
  # Bump if the persisted representation changes incompatibly; older/unknown
  # versions are ignored on load.
  @format_version 1
  @legacy_credential_format_version 1
  @credential_format_version 2

  @doc "Atomically persist the desired Wi-Fi `state` under `dir`. Best-effort; never raises."
  @spec save(Path.t(), state()) :: :ok | {:error, term()}
  def save(dir, %{} = state) do
    contents = :erlang.term_to_binary({@format_version, state})

    case AtomicFile.write(path(dir), contents, directory_root: dir) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to persist Wi-Fi state to #{inspect(dir)}: #{inspect(reason)}")
        error
    end
  rescue
    error ->
      Logger.warning("Failed to persist Wi-Fi state to #{inspect(dir)}: #{inspect(error)}")
      {:error, error}
  end

  @doc "Load the persisted Wi-Fi state from `dir`, or `:empty` if absent/unusable."
  @spec load(Path.t()) :: {:ok, state()} | :empty
  def load(dir) do
    case read_authority(dir) do
      {:ok, state} -> {:ok, state}
      :empty -> :empty
      {:error, {:read, reason}} -> warn_empty(dir, "could not read", reason)
      {:error, :unrecognized_format} -> warn_empty(dir, "unrecognized/incompatible", :format)
      {:error, :corrupt} -> warn_empty(dir, "corrupt", :format)
    end
  end

  @doc "Strictly read the owner marker while preserving missing, corrupt, and I/O outcomes."
  @spec read_authority(Path.t()) :: {:ok, state()} | :empty | {:error, term()}
  def read_authority(dir) do
    case File.read(path(dir)) do
      {:ok, binary} -> decode_authority(binary)
      {:error, :enoent} -> :empty
      {:error, reason} -> {:error, {:read, reason}}
    end
  rescue
    _error -> {:error, :corrupt}
  catch
    _kind, _reason -> {:error, :corrupt}
  end

  @doc "Remove any persisted Wi-Fi state under `dir`."
  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(dir) do
    # Marker first is deliberate: never destroy the only reconnect credential while
    # an enabled secretless marker might remain authoritative. If marker removal is
    # exact but credential removal fails, the caller can safely retry only the latter.
    with :ok <- AtomicFile.remove(path(dir), directory_root: dir),
         :ok <- AtomicFile.remove(credential_path(dir), directory_root: dir) do
      :ok
    end
  end

  @doc "Durably remove abandoned atomic-write temp files for the marker and credential sidecar."
  @spec cleanup_temporary_artifacts(Path.t()) :: :ok | {:error, term()}
  def cleanup_temporary_artifacts(dir) do
    case File.ls(dir) do
      {:ok, entries} -> remove_temporary_artifacts(dir, entries)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:list_temporary_artifacts, reason}}
    end
  rescue
    _error -> {:error, :temporary_artifact_cleanup_failed}
  catch
    _kind, _reason -> {:error, :temporary_artifact_cleanup_failed}
  end

  @doc """
  Durably persist a reconnect credential for a SECRETLESS owner marker.

  Written to a sidecar file that `load/1` never reads, so the marker stays free of
  plaintext credential material while the device keeps everything it needs to
  reassociate after a reboot. `binding` names the marker this credential belongs to
  and is enforced on read.

  The sidecar may temporarily retain both the prior and candidate bindings while an
  owner-marker write is ambiguous. This is what lets a later strict authority read
  choose either marker without having destroyed the credential that marker needs.
  `retain_credential/2` prunes the losing choices once authority is known.

  Passing `nil` clears the complete sidecar (a committed disabled or credential-free
  marker must not leave a stale secret behind).
  """
  @spec put_credential(Path.t(), Secret.t() | nil, credential_binding()) :: :ok | {:error, term()}
  def put_credential(dir, nil, _binding), do: clear_credential(dir)

  def put_credential(dir, secret, %{} = binding) do
    with {:ok, entries} <- read_credential_entries(dir),
         secret when is_binary(secret) <- Secret.unwrap(secret),
         :ok <- write_credential_entries(dir, Map.put(entries, binding_key(binding), secret)) do
      :ok
    else
      {:error, _reason} = error -> log_credential_write_error(dir, error)
      _other -> log_credential_write_error(dir, {:error, :credential_write_failed})
    end
  rescue
    # Deliberately does NOT interpolate the exception: a raise from term_to_binary,
    # Secret.unwrap/1, or the writer could otherwise carry a credential into the log.
    _error -> log_credential_write_error(dir, {:error, :credential_write_failed})
  catch
    _kind, _reason -> log_credential_write_error(dir, {:error, :credential_write_failed})
  end

  @doc """
  Fetch the sidecar credential bound to `binding`.

  Returns a `Secret` so the plaintext stays wrapped as it crosses back out, and
  only when an entry matches `binding` EXACTLY — unrelated candidate/prior entries
  remain inaccessible. Returns `:empty` only when the sidecar or exact binding is
  absent; unreadable or corrupt credential authority returns `{:error, reason}`.
  """
  @spec credential(Path.t(), credential_binding()) ::
          {:ok, Secret.t()} | :empty | {:error, term()}
  def credential(dir, %{} = binding) do
    with {:ok, entries} <- read_credential_entries(dir) do
      case Map.fetch(entries, binding_key(binding)) do
        {:ok, secret} -> {:ok, Secret.new(secret)}
        :error -> :empty
      end
    end
  rescue
    _error -> {:error, :credential_read_failed}
  catch
    _kind, _reason -> {:error, :credential_read_failed}
  end

  @doc "Durably retain exactly the credential bound to the authoritative marker."
  @spec retain_credential(Path.t(), credential_binding()) :: :ok | {:error, term()}
  def retain_credential(dir, %{} = binding) do
    key = binding_key(binding)

    with {:ok, entries} <- read_credential_entries(dir),
         {:ok, secret} <- fetch_retained_credential(entries, key),
         :ok <- write_credential_entries(dir, %{key => secret}) do
      :ok
    end
  rescue
    _error -> {:error, :credential_write_failed}
  catch
    _kind, _reason -> {:error, :credential_write_failed}
  end

  @doc "Durably remove every persisted sidecar credential under `dir`."
  @spec clear_credential(Path.t()) :: :ok | {:error, term()}
  def clear_credential(dir) do
    AtomicFile.remove(credential_path(dir), directory_root: dir)
  end

  defp remove_temporary_artifacts(dir, entries) do
    entries
    |> Enum.filter(&temporary_artifact?/1)
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case AtomicFile.remove(Path.join(dir, entry), directory_root: dir) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:remove_temporary_artifact, reason}}}
      end
    end)
  end

  defp temporary_artifact?(entry) when is_binary(entry) do
    Enum.any?([@filename, @credential_filename], fn filename ->
      prefix = filename <> ".tmp."
      byte_size(entry) > byte_size(prefix) and binary_part(entry, 0, byte_size(prefix)) == prefix
    end)
  end

  defp temporary_artifact?(_entry), do: false

  # Only nonsecret marker identity participates in the binding.
  defp binding_key(%{} = binding) do
    {Map.get(binding, :ssid), Map.get(binding, :desired_activation_id)}
  end

  defp read_credential_entries(dir) do
    case File.read(credential_path(dir)) do
      {:ok, contents} -> decode_credential_entries(contents)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, {:credential_read_failed, reason}}
    end
  end

  defp decode_credential_entries(contents) do
    case safe_binary_to_term(contents) do
      {@credential_format_version, entries} when is_map(entries) ->
        if valid_credential_entries?(entries),
          do: {:ok, entries},
          else: {:error, :credential_corrupt}

      {@legacy_credential_format_version, key, secret}
      when is_binary(secret) ->
        if valid_credential_key?(key),
          do: {:ok, %{key => secret}},
          else: {:error, :credential_corrupt}

      _other ->
        {:error, :credential_corrupt}
    end
  rescue
    _error -> {:error, :credential_corrupt}
  catch
    _kind, _reason -> {:error, :credential_corrupt}
  end

  defp valid_credential_entries?(entries) do
    Enum.all?(entries, fn {key, secret} ->
      valid_credential_key?(key) and is_binary(secret)
    end)
  end

  defp valid_credential_key?({ssid, activation_id}) do
    (is_binary(ssid) or is_nil(ssid)) and
      (is_binary(activation_id) or is_nil(activation_id))
  end

  defp valid_credential_key?(_key), do: false

  defp fetch_retained_credential(entries, key) do
    case Map.fetch(entries, key) do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :credential_missing}
    end
  end

  defp write_credential_entries(dir, entries) do
    record = {@credential_format_version, entries}
    AtomicFile.write(credential_path(dir), :erlang.term_to_binary(record), directory_root: dir)
  end

  defp log_credential_write_error(dir, {:error, _reason} = error) do
    Logger.warning("Failed to persist Wi-Fi credential to #{inspect(dir)}")
    error
  end

  defp decode_authority(binary) do
    case safe_binary_to_term(binary) do
      {@format_version, %{enabled: enabled, version: version} = state}
      when is_boolean(enabled) and is_integer(version) ->
        {:ok, state}

      {@format_version, %{enabled: _, version: _}} ->
        {:error, :corrupt}

      _other ->
        {:error, :unrecognized_format}
    end
  rescue
    _error -> {:error, :corrupt}
  catch
    _kind, _reason -> {:error, :corrupt}
  end

  defp safe_binary_to_term(binary), do: :erlang.binary_to_term(binary, [:safe])

  defp warn_empty(dir, what, detail) do
    Logger.warning("Ignoring #{what} persisted Wi-Fi state in #{inspect(dir)}: #{inspect(detail)}")
    :empty
  end

  defp path(dir), do: Path.join(dir, @filename)
  defp credential_path(dir), do: Path.join(dir, @credential_filename)
end
