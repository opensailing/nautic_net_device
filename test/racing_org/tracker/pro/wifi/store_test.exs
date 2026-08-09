defmodule RacingOrg.Tracker.Pro.WiFi.StoreTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WiFi.Store
  alias RacingOrg.Tracker.Pro.WiFiManager.Secret

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_wifi_store_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp state do
    %{version: 3, enabled: true, ssid: "boat-net", psk: "hunter2"}
  end

  test "save then load round-trips the desired state", %{dir: dir} do
    assert :ok = Store.save(dir, state())
    assert {:ok, loaded} = Store.load(dir)
    assert loaded.version == 3
    assert loaded.enabled == true
    assert loaded.ssid == "boat-net"
    assert loaded.psk == "hunter2"
  end

  test "load returns :empty when nothing is persisted", %{dir: dir} do
    assert :empty = Store.load(dir)
  end

  test "save uses an atomic rename and leaves no temp file", %{dir: dir} do
    assert :ok = Store.save(dir, state())
    refute File.exists?(Path.join(dir, "current.wifi.tmp"))
    assert File.exists?(Path.join(dir, "current.wifi"))
  end

  test "load recovers from a corrupt file by returning :empty", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wifi"), <<0, 1, 2, 3, 255>>)
    assert :empty = Store.load(dir)
  end

  test "load ignores an unknown format version", %{dir: dir} do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wifi"), :erlang.term_to_binary({999, %{}}))
    assert :empty = Store.load(dir)
  end

  test "strict authority rejects malformed required field types", %{dir: dir} do
    File.mkdir_p!(dir)

    for invalid <- [
          %{version: 1, enabled: :yes},
          %{version: "1", enabled: false}
        ] do
      File.write!(Path.join(dir, "current.wifi"), :erlang.term_to_binary({1, invalid}))
      assert {:error, :corrupt} = Store.read_authority(dir)
    end
  end

  test "credential lookup distinguishes an unreadable sidecar from an absent binding", %{dir: dir} do
    binding = %{ssid: "prior", desired_activation_id: <<1::256>>}
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "current.wifi.credential"), <<0, 1, 2, 3>>)

    assert {:error, :credential_corrupt} = Store.credential(dir, binding)
  end

  test "credential sidecar preserves concurrent prior and candidate bindings", %{dir: dir} do
    prior = %{ssid: "prior", desired_activation_id: <<1::256>>}
    candidate = %{ssid: "candidate", desired_activation_id: <<2::256>>}

    assert :ok = Store.put_credential(dir, Secret.new("prior-secret"), prior)
    assert :ok = Store.put_credential(dir, Secret.new("candidate-secret"), candidate)

    assert {:ok, _prior_secret} = Store.credential(dir, prior)
    assert {:ok, _candidate_secret} = Store.credential(dir, candidate)
  end

  test "legacy single-binding sidecars remain readable and upgrade without losing the prior", %{
    dir: dir
  } do
    prior = %{ssid: "prior", desired_activation_id: <<1::256>>}
    candidate = %{ssid: "candidate", desired_activation_id: <<2::256>>}

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "current.wifi.credential"),
      :erlang.term_to_binary({1, {prior.ssid, prior.desired_activation_id}, "prior-secret"})
    )

    assert {:ok, _prior_secret} = Store.credential(dir, prior)
    assert :ok = Store.put_credential(dir, Secret.new("candidate-secret"), candidate)
    assert {:ok, _prior_secret} = Store.credential(dir, prior)
    assert {:ok, _candidate_secret} = Store.credential(dir, candidate)
  end

  test "retaining one credential binding durably prunes superseded choices", %{dir: dir} do
    prior = %{ssid: "prior", desired_activation_id: <<1::256>>}
    candidate = %{ssid: "candidate", desired_activation_id: <<2::256>>}

    assert :ok = Store.put_credential(dir, Secret.new("prior-secret"), prior)
    assert :ok = Store.put_credential(dir, Secret.new("candidate-secret"), candidate)
    assert :ok = Store.retain_credential(dir, candidate)

    assert :empty = Store.credential(dir, prior)
    assert {:ok, _candidate_secret} = Store.credential(dir, candidate)
  end

  test "cleanup removes abandoned atomic temp files without touching unrelated files", %{dir: dir} do
    File.mkdir_p!(dir)
    marker_temp = Path.join(dir, "current.wifi.tmp.abandoned")
    credential_temp = Path.join(dir, "current.wifi.credential.tmp.abandoned")
    unrelated = Path.join(dir, "operator-note")

    File.write!(marker_temp, "marker")
    File.write!(credential_temp, "plaintext-secret")
    File.write!(unrelated, "keep")

    assert :ok = Store.cleanup_temporary_artifacts(dir)
    refute File.exists?(marker_temp)
    refute File.exists?(credential_temp)
    assert File.read!(unrelated) == "keep"
  end

  test "clear removes the persisted file", %{dir: dir} do
    Store.save(dir, state())
    assert :ok = Store.clear(dir)
    assert :empty = Store.load(dir)
  end
end
