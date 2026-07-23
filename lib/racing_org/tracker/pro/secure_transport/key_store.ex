defmodule RacingOrg.Tracker.Pro.SecureTransport.KeyStore do
  @moduledoc """
  The device's long-term Ed25519 IDENTITY key store.

  This is the device side of the Phase 2 device-identity model. The device's
  cryptographic identity-of-record is a long-term Ed25519 keypair whose PUBLIC key
  the server records (after a proof-of-possession-verified claim) as a
  `RacingOrg.Devices.DeviceKey`. This module owns the device's STABLE PRIVATE
  identity: it is generated exactly once (on first use), persisted to a writable
  path, and reloaded unchanged on every subsequent boot.

  ## What is persisted

  Only the 32-byte Ed25519 PRIVATE SEED is written to disk. The public key is
  DERIVED deterministically from the seed via
  `Primitives.ed25519_public_from_secret/1` (verified on OTP 28:
  `:crypto.generate_key(:eddsa, :ed25519, seed)` reproduces the matching public
  half, and signatures made with the seed verify under it). Storing only the seed
  keeps the on-disk footprint minimal and avoids any chance of a stored public key
  disagreeing with the stored private key.

  ## File location + permissions

  On the device target the seed lives under `/data` (persistent + writable across
  reboots/OTA): `/data/secure_transport/device_ed25519.key`. The base path is
  configurable via

      config :racing_org_tracker_pro, #{inspect(__MODULE__)}, base_path: "/some/dir"

  (defaulting to `/data/secure_transport`), so the host/test target points at a
  temp dir. The seed file is written ATOMICALLY (write to a temp file in the
  same dir, `chmod 0600`, then rename) and the containing directory is created with
  restrictive (`0700`) perms.

  ## Identity struct

  `load_or_generate/1` returns `{:ok, %{private_key:, public_key:, fingerprint:}}`
  where `fingerprint` is the canonical lowercase hex `SHA-256(public_key)` (64
  chars) — IDENTICAL to the server's `RacingOrg.Devices.DeviceKey.fingerprint/1`.

  ## Hardware-backed keys (future)

  NervesKey / ATECC608 secure-element storage is a future option. The seam is the
  `t:backend/0` indirection: today only the `:file` backend (this module) is
  implemented; a `:nerves_key` backend would generate/sign inside the secure
  element without the private seed ever touching the filesystem. Callers depend on
  the `load_or_generate/1` / `fingerprint/1` surface, not on the file layout.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives

  @type identity :: %{
          private_key: binary(),
          public_key: binary(),
          fingerprint: String.t()
        }

  @typedoc "The storage backend. Only `:file` is implemented today (NervesKey is a future seam)."
  @type backend :: :file

  @default_base_path "/data/secure_transport"
  @key_filename "device_ed25519.key"
  @seed_size 32
  @dir_mode 0o700
  @file_mode 0o600

  @doc "The default base path for the identity seed file (`/data/...` on target)."
  @spec default_base_path() :: String.t()
  def default_base_path, do: @default_base_path

  @doc """
  Loads the device's long-term identity, generating + persisting it on first use.

  On the FIRST call (no seed file present) a fresh Ed25519 keypair is generated via
  `Primitives.generate_identity_keypair/0`, the 32-byte private seed is written
  atomically with `0600` perms, and the identity is returned. On EVERY subsequent
  call the existing seed is read back and the SAME identity is returned (the device
  never regenerates its stable identity).

  Options:

    * `:base_path` — override the directory holding the seed file (defaults to the
      configured `:base_path`, then `#{inspect(@default_base_path)}`). Tests/host
      pass a temp dir.

  Returns `{:ok, identity}` or `{:error, reason}` (e.g. `{:error, {:read, posix}}`,
  `{:error, {:write, posix}}`, `{:error, :corrupt_seed}` for a wrong-sized file).
  """
  @spec load_or_generate(keyword()) :: {:ok, identity()} | {:error, term()}
  def load_or_generate(opts \\ []) do
    path = key_path(opts)

    case read_seed(path) do
      {:ok, seed} -> {:ok, identity_from_seed(seed)}
      {:error, :enoent} -> generate_and_persist(path)
      {:error, _} = err -> err
    end
  end

  @doc """
  Loads the existing identity WITHOUT generating one.

  Returns `{:ok, identity}` or `{:error, :not_provisioned}` when no seed file
  exists yet. Useful for consumers (handshake/claim wiring) that must not silently
  mint an identity.
  """
  @spec load(keyword()) :: {:ok, identity()} | {:error, term()}
  def load(opts \\ []) do
    case read_seed(key_path(opts)) do
      {:ok, seed} -> {:ok, identity_from_seed(seed)}
      {:error, :enoent} -> {:error, :not_provisioned}
      {:error, _} = err -> err
    end
  end

  @doc """
  Canonical fingerprint of a raw 32-byte Ed25519 public key: lowercase hex
  `SHA-256(public_key)` (64 chars).

  IDENTICAL to the server's `RacingOrg.Devices.DeviceKey.fingerprint/1`. Uses
  `Primitives.sha256/1` (the crypto core) — never hand-rolls hashing.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(public_key) when is_binary(public_key) do
    public_key
    |> Primitives.sha256()
    |> Base.encode16(case: :lower)
  end

  @doc "Absolute path of the identity seed file for the given/configured base path."
  @spec key_path(keyword()) :: String.t()
  def key_path(opts \\ []), do: Path.join(base_path(opts), @key_filename)

  ## --- internal ------------------------------------------------------------

  defp base_path(opts) do
    Keyword.get(opts, :base_path) || configured_base_path() || @default_base_path
  end

  defp configured_base_path do
    :racing_org_tracker_pro
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:base_path)
  end

  defp identity_from_seed(<<seed::binary-size(@seed_size)>>) do
    public_key = Primitives.ed25519_public_from_secret(seed)

    %{
      private_key: seed,
      public_key: public_key,
      fingerprint: fingerprint(public_key)
    }
  end

  defp read_seed(path) do
    case File.read(path) do
      {:ok, <<seed::binary-size(@seed_size)>>} -> {:ok, seed}
      {:ok, _other} -> {:error, :corrupt_seed}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp generate_and_persist(path) do
    {public_key, private_seed} = Primitives.generate_identity_keypair()

    with :ok <- ensure_dir(Path.dirname(path)),
         :ok <- atomic_write(path, private_seed) do
      {:ok,
       %{
         private_key: private_seed,
         public_key: public_key,
         fingerprint: fingerprint(public_key)
       }}
    end
  end

  defp ensure_dir(dir) do
    case File.mkdir_p(dir) do
      :ok ->
        # Best-effort restrictive perms on the containing dir (a no-op surprise on
        # exotic filesystems must not fail provisioning).
        _ = File.chmod(dir, @dir_mode)
        :ok

      {:error, reason} ->
        {:error, {:mkdir, reason}}
    end
  end

  # Atomic, 0600 write: write to a unique temp file in the SAME directory, chmod it
  # 0600 BEFORE it carries the seed under its final name, then rename over the
  # target (rename within a dir is atomic on the device's filesystem). A crash
  # mid-write leaves either the old seed or nothing — never a partial seed.
  defp atomic_write(path, contents) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- write_file(tmp, contents),
         :ok <- chmod_file(tmp, @file_mode),
         :ok <- rename_file(tmp, path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp write_file(path, contents) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp chmod_file(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod, reason}}
    end
  end

  defp rename_file(src, dst) do
    case File.rename(src, dst) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename, reason}}
    end
  end
end
