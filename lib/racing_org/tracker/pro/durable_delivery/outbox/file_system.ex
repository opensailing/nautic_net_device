defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.FileSystem do
  @moduledoc """
  Injectable filesystem operations used by the durable outbox.

  The behavior keeps append, fsync, scan, quarantine, and torn-tail recovery
  observable in focused host tests while the default implementation delegates
  to `File` and OTP's synchronous `:file` API.
  """

  @type device :: term()
  @type modes :: [atom()]

  @callback read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  @callback list_dir(Path.t()) :: {:ok, [binary()]} | {:error, File.posix()}
  @callback mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  @callback chmod(Path.t(), non_neg_integer()) :: :ok | {:error, File.posix()}
  @callback open(Path.t(), modes()) :: {:ok, device()} | {:error, File.posix()}
  @callback write(device(), iodata()) :: :ok | {:error, File.posix()}
  @callback sync(device()) :: :ok | {:error, File.posix()}
  @callback close(device()) :: :ok | {:error, File.posix()}
  @callback rename(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  @callback remove(Path.t()) :: :ok | {:error, File.posix()}
  @callback position(device(), :bof | :cur | :eof | non_neg_integer()) ::
              {:ok, non_neg_integer()} | {:error, File.posix()}
  @callback truncate(device()) :: :ok | {:error, File.posix()}

  @doc false
  def read(path), do: File.read(path)

  @doc false
  def list_dir(path), do: File.ls(path)

  @doc false
  def mkdir_p(path), do: File.mkdir_p(path)

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
  def position(device, location), do: :file.position(device, location)

  @doc false
  def truncate(device), do: :file.truncate(device)
end
