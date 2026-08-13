defmodule RacingOrg.Tracker.Pro.DataSetUploaderTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.DataSetUploader

  @receipt %{
    stream: :telemetry,
    device_id: <<1::128>>,
    credential_epoch: 7,
    storage_epoch: <<2::128>>,
    sequence: 11,
    payload_hash: <<3::256>>,
    cumulative_sequence: 0
  }

  defmodule FakeProducer do
    def admit(binary, opts) do
      outbox = Keyword.fetch!(opts, :outbox)
      send(outbox.test_pid, {:admit, binary, opts})
      outbox.result
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "data_set_uploader_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "boot admits exact pending bytes and removes the legacy file only after a valid Outbox receipt", %{dir: dir} do
    path = write_pending(dir, "boot-pending", <<0, 1, 2, 3, 255>>)
    test_pid = self()

    remove_file = fn source_path ->
      result = File.rm(source_path)
      send(test_pid, {:remove, source_path, result})
      result
    end

    start_supervised!(
      {DataSetUploader,
       name: nil,
       temp_dir: dir,
       delivery: :durable,
       outbox: %{test_pid: self(), result: {:ok, @receipt}},
       producer: FakeProducer,
       remove_file: remove_file,
       retry_after: 10}
    )

    assert_receive {:admit, <<0, 1, 2, 3, 255>>, opts}
    assert Keyword.fetch!(opts, :source_id) == path
    assert Keyword.keys(opts) |> Enum.sort() == [:outbox, :source_id]
    assert_receive {:remove, ^path, :ok}
    refute File.exists?(path)
  end

  test "identity, backpressure, and durability failures retain and retry the exact pending bytes", %{dir: dir} do
    failures = [
      {:error, :identity_unbound},
      {:error, :storage_epoch_mismatch},
      {:error, {:backpressure, :entry_capacity}},
      {:error, {:durability_uncertain, {:file_sync, :eio}}}
    ]

    for {failure, index} <- Enum.with_index(failures) do
      path = write_pending(dir, "failure-#{index}", <<index, 9, 8, 7>>)
      test_pid = self()

      remove_file = fn source_path ->
        send(test_pid, {:unexpected_remove, source_path})
        File.rm(source_path)
      end

      id = make_ref()

      start_supervised!(
        {DataSetUploader,
         name: nil,
         temp_dir: dir,
         delivery: :durable,
         outbox: %{test_pid: self(), result: failure},
         producer: FakeProducer,
         remove_file: remove_file,
         retry_after: 10},
        id: id
      )

      assert_receive {:admit, <<^index, 9, 8, 7>>, first_opts}
      assert Keyword.fetch!(first_opts, :source_id) == path
      assert_receive {:admit, <<^index, 9, 8, 7>>, second_opts}
      assert Keyword.fetch!(second_opts, :source_id) == path
      assert File.read!(path) == <<index, 9, 8, 7>>
      refute_receive {:unexpected_remove, ^path}

      stop_supervised!(id)
      File.rm!(path)
      flush_admissions()
    end
  end

  test "transport-like success cannot retire a durable source file", %{dir: dir} do
    path = write_pending(dir, "not-a-receipt", "encoded-data-set")
    test_pid = self()

    start_supervised!(
      {DataSetUploader,
       name: nil,
       temp_dir: dir,
       delivery: :durable,
       outbox: %{test_pid: self(), result: :ok},
       producer: FakeProducer,
       remove_file: fn source_path ->
         send(test_pid, {:unexpected_remove, source_path})
         File.rm(source_path)
       end,
       retry_after: 10}
    )

    assert_receive {:admit, "encoded-data-set", _opts}
    assert_receive {:admit, "encoded-data-set", _opts}
    assert File.exists?(path)
    refute_receive {:unexpected_remove, ^path}
  end

  test "after admission, a source removal failure retries removal without waiting for transport or re-admitting", %{
    dir: dir
  } do
    path = write_pending(dir, "remove-retry", "encoded-data-set")
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    remove_file = fn source_path ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)

      result =
        case attempt do
          1 -> {:error, :eacces}
          2 -> File.rm(source_path)
        end

      send(test_pid, {:remove_attempt, attempt, source_path, result})
      result
    end

    start_supervised!(
      {DataSetUploader,
       name: nil,
       temp_dir: dir,
       delivery: :durable,
       outbox: %{test_pid: self(), result: {:ok, @receipt}},
       producer: FakeProducer,
       remove_file: remove_file,
       retry_after: 10}
    )

    assert_receive {:admit, "encoded-data-set", _opts}
    assert_receive {:remove_attempt, 1, ^path, {:error, :eacces}}
    assert File.exists?(path)
    assert_receive {:remove_attempt, 2, ^path, :ok}
    refute File.exists?(path)
    refute_receive {:admit, "encoded-data-set", _opts}, 30
  end

  test "durable mode never calls the legacy HTTP or UDP upload path", %{dir: dir} do
    test_pid = self()

    start_supervised!(
      {DataSetUploader,
       name: nil,
       temp_dir: dir,
       delivery: :durable,
       outbox: %{test_pid: self(), result: {:ok, @receipt}},
       producer: FakeProducer,
       upload: fn binary, via -> send(test_pid, {:legacy_upload, binary, via}) end,
       retry_after: 10}
    )

    refute_receive {:legacy_upload, _binary, _via}, 30
  end

  test "legacy delivery remains available for uplink deployments without an Outbox owner", %{dir: dir} do
    path = write_pending(dir, "uplink-pending", "uplink-data-set")
    test_pid = self()

    start_supervised!(
      {DataSetUploader,
       name: nil,
       temp_dir: dir,
       delivery: :legacy,
       via: :udp,
       ping?: false,
       upload: fn binary, via ->
         send(test_pid, {:legacy_upload, binary, via})
         :ok
       end,
       retry_after: 10}
    )

    assert_receive {:legacy_upload, "uplink-data-set", :udp}
    refute File.exists?(path)
  end

  defp write_pending(dir, filename, binary) do
    path = Path.join(dir, filename)
    File.write!(path, binary)
    path
  end

  defp flush_admissions do
    receive do
      {:admit, _binary, _opts} -> flush_admissions()
    after
      0 -> :ok
    end
  end
end
