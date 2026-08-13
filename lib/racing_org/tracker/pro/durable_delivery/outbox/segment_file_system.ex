defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystem do
  @moduledoc false

  @on_load :load_nif

  @type root :: reference()
  @type segment :: reference()
  @type bound_entry :: reference()
  @type identity :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type file_info :: %{
          major_device: non_neg_integer(),
          minor_device: non_neg_integer(),
          inode: non_neg_integer(),
          mode: non_neg_integer(),
          links: non_neg_integer(),
          size: non_neg_integer()
        }

  @callback open_root(module(), Path.t(), identity()) :: {:ok, root()} | {:error, term()}
  @callback close_root(root()) :: :ok | {:error, term()}
  @callback try_lock_root(root()) :: :ok | {:error, term()}
  @callback create(root(), binary(), non_neg_integer()) :: {:ok, segment()} | {:error, term()}
  @callback chmod(segment(), non_neg_integer()) :: :ok | {:error, term()}
  @callback write(segment(), iodata()) :: :ok | {:error, term()}
  @callback sync_file(segment()) :: :ok | {:error, term()}
  @callback sync_directory(segment()) :: :ok | {:error, term()}
  @callback unlink_empty(segment()) :: :ok | {:error, term()}
  @callback file_info(segment()) :: {:ok, file_info()} | {:error, term()}
  @callback close(segment()) :: :ok | {:error, term()}
  @callback bind_entry(Path.t(), Path.t(), :regular | :directory, identity(), identity(), identity()) ::
              {:ok, bound_entry()} | {:error, term()}
  @callback bound_info(bound_entry()) :: {:ok, file_info()} | {:error, term()}
  @callback read_bound(bound_entry(), non_neg_integer()) :: {:ok, binary()} | :eof | {:error, term()}
  @callback sync_bound(bound_entry()) :: :ok | {:error, term()}
  @callback remove_bound(bound_entry()) :: :ok | {:error, term()}
  @callback close_bound(bound_entry()) :: :ok | {:error, term()}

  @doc false
  def adoption_prepare(_source, _destination, _directory_root), do: :erlang.nif_error(:not_loaded)

  @doc false
  def adoption_commit(_adoption, _fault), do: :erlang.nif_error(:not_loaded)

  @doc false
  def adoption_close(_adoption), do: :erlang.nif_error(:not_loaded)

  def load_nif do
    target = Application.get_env(:racing_org_tracker_pro, :target, :host)
    path = Path.join([:code.priv_dir(:racing_org_tracker_pro), "native", to_string(target), "outbox_segment"])
    :erlang.load_nif(String.to_charlist(path), 0)
  end

  @doc false
  def open_root(_file_system, path, identity), do: nif_open_root(path, identity)

  @doc false
  def nif_open_root(_path, _identity), do: :erlang.nif_error(:not_loaded)

  @doc false
  def close_root(_root), do: :erlang.nif_error(:not_loaded)

  @doc false
  def try_lock_root(_root), do: :erlang.nif_error(:not_loaded)

  @doc false
  def create(_root, _basename, _mode), do: :erlang.nif_error(:not_loaded)

  @doc false
  def chmod(_segment, _mode), do: :erlang.nif_error(:not_loaded)

  @doc false
  def write(_segment, _bytes), do: :erlang.nif_error(:not_loaded)

  @doc false
  def sync_file(_segment), do: :erlang.nif_error(:not_loaded)

  @doc false
  def sync_directory(_segment), do: :erlang.nif_error(:not_loaded)

  @doc false
  def unlink_empty(_segment), do: :erlang.nif_error(:not_loaded)

  @doc false
  def file_info(_segment), do: :erlang.nif_error(:not_loaded)

  @doc false
  def close(_segment), do: :erlang.nif_error(:not_loaded)

  @doc false
  def bind_entry(_root, _path, _type, _identity, _parent_identity, _root_identity),
    do: :erlang.nif_error(:not_loaded)

  @doc false
  def bound_info(_entry), do: :erlang.nif_error(:not_loaded)

  @doc false
  def read_bound(_entry, _count), do: :erlang.nif_error(:not_loaded)

  @doc false
  def sync_bound(_entry), do: :erlang.nif_error(:not_loaded)

  @doc false
  def remove_bound(_entry), do: :erlang.nif_error(:not_loaded)

  @doc false
  def close_bound(_entry), do: :erlang.nif_error(:not_loaded)
end
