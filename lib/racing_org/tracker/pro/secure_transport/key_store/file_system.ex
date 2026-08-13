defmodule RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem do
  @moduledoc """
  Injectable POSIX filesystem operations used by the device identity key store.

  The small behavior keeps durability ordering observable in host tests while the
  default implementation delegates to `File` and OTP's synchronous `:file` API.

  Adapters must not raise, throw, exit, or return a malformed result after an
  operation has taken effect. In particular, `open/2` must either return every
  acquired device to its caller or close that device internally before failing;
  callers cannot recover a descriptor that never crossed the callback boundary.
  Once `close/1` is invoked, ownership of the device is transferred to the adapter:
  every return path must consume the device, even when reporting an error.

  Every filesystem effect must also be synchronous with the callback process.
  An adapter must not delegate an operation to a helper that can write, rename,
  remove, sync, or otherwise take effect after the callback process exits. If an
  implementation uses an external worker, it must monitor its caller and prove
  that the effect is cancelled or durably fenced before caller termination can
  release a higher-level ownership lease. Checkpoint-head transition timeouts use
  caller death as that cancellation boundary; a delayed effect that survives it
  can corrupt a later lock owner.

  The callbacks marked optional are optional only for consumers that do not use
  those operations. `DesiredState.AtomicFile` performs operation-specific
  preflight: rooted writes require `read/2`, `file_info/1`, and `lstat/1`, and
  creating a missing rooted directory additionally requires `mkdir/1` and
  `rmdir/1`. An injected adapter must implement the complete surface required by
  the operation it is used for.
  """

  @type device :: term()
  @type modes :: [atom()]
  @type file_error ::
          File.posix() | :badarg | :terminated | {:no_translation, :unicode, :latin1}

  @callback read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  @callback read(device(), non_neg_integer()) ::
              {:ok, binary()} | :eof | {:error, file_error()}
  @callback file_info(device()) :: {:ok, File.Stat.t()} | {:error, File.posix() | :badarg}
  @callback list_dir(Path.t()) :: {:ok, [binary()]} | {:error, File.posix()}
  @callback lstat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  @callback read_link(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  @callback mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  @callback mkdir(Path.t()) :: :ok | {:error, File.posix()}
  @callback chmod(Path.t(), non_neg_integer()) :: :ok | {:error, File.posix()}
  @callback open(Path.t(), modes()) :: {:ok, device()} | {:error, File.posix()}
  @callback write(device(), iodata()) :: :ok | {:error, File.posix()}
  @callback sync(device()) :: :ok | {:error, File.posix()}
  @callback close(device()) :: :ok | {:error, File.posix()}
  @callback rename(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  @callback remove(Path.t()) :: :ok | {:error, File.posix()}
  @callback rmdir(Path.t()) :: :ok | {:error, File.posix()}

  @optional_callbacks read: 2, file_info: 1, list_dir: 1, lstat: 1, read_link: 1, mkdir: 1, rmdir: 1

  @doc false
  def read(path), do: File.read(path)

  @doc false
  def read(device, count), do: :file.read(device, count)

  @doc false
  def file_info(device) do
    with {:ok, info} <- :file.read_file_info(device) do
      {:ok, File.Stat.from_record(info)}
    end
  end

  @doc false
  def list_dir(path), do: File.ls(path)

  @doc false
  def lstat(path), do: File.lstat(path)

  @doc false
  def read_link(path), do: File.read_link(path)

  @doc false
  def mkdir_p(path), do: File.mkdir_p(path)

  @doc false
  def mkdir(path), do: File.mkdir(path)

  @doc false
  def chmod(path, mode), do: File.chmod(path, mode)

  @doc false
  def open(path, modes), do: File.open(path, modes)

  @doc false
  def write(device, contents), do: :file.write(device, contents)

  @doc false
  def sync(device), do: :file.sync(device)

  @doc false
  def close(device), do: :file.close(device)

  @doc false
  def rename(source, destination), do: File.rename(source, destination)

  @doc false
  def remove(path), do: File.rm(path)

  @doc false
  def rmdir(path), do: File.rmdir(path)
end
