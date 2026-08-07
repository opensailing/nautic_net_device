defmodule RacingOrg.Tracker.Pro.SecureTransport.KeyStore.FileSystem do
  @moduledoc """
  Injectable POSIX filesystem operations used by the device identity key store.

  The small behavior keeps durability ordering observable in host tests while the
  default implementation delegates to `File` and OTP's synchronous `:file` API.
  """

  @type device :: term()
  @type modes :: [atom()]

  @callback read(Path.t()) :: {:ok, binary()} | {:error, File.posix()}
  @callback mkdir_p(Path.t()) :: :ok | {:error, File.posix()}
  @callback chmod(Path.t(), non_neg_integer()) :: :ok | {:error, File.posix()}
  @callback open(Path.t(), modes()) :: {:ok, device()} | {:error, File.posix()}
  @callback write(device(), iodata()) :: :ok | {:error, File.posix()}
  @callback sync(device()) :: :ok | {:error, File.posix()}
  @callback close(device()) :: :ok | {:error, File.posix()}
  @callback rename(Path.t(), Path.t()) :: :ok | {:error, File.posix()}
  @callback remove(Path.t()) :: :ok | {:error, File.posix()}

  @doc false
  def read(path), do: File.read(path)

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
end
