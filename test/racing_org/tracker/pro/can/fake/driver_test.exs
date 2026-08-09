defmodule RacingOrg.Tracker.Pro.CAN.Fake.DriverTest do
  use ExUnit.Case

  alias RacingOrg.Tracker.Pro.CAN.Fake.Driver
  alias RacingOrg.Tracker.Pro.CAN.Fake.Server, as: FakeServer
  alias RacingOrg.Tracker.Pro.CAN.Server, as: CANServer

  test "waits for a stale fake server to terminate before claiming a fresh driver" do
    test_pid = self()

    old_owner =
      spawn(fn ->
        {:ok, fake_server} = FakeServer.start_link([])
        send(test_pid, {:old_fake_server, self(), fake_server})
        Process.sleep(:infinity)
      end)

    assert_receive {:old_fake_server, ^old_owner, old_fake_server}

    new_owner =
      spawn(fn ->
        result =
          CANServer.start_link(
            driver: Driver,
            handlers: []
          )

        send(test_pid, {:new_can_server, self(), result})
        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      stop_process(new_owner)
      stop_process(old_owner)
    end)

    refute_receive {:new_can_server, ^new_owner, _result}, 50

    old_fake_ref = Process.monitor(old_fake_server)
    Process.exit(old_owner, :shutdown)
    assert_receive {:DOWN, ^old_fake_ref, :process, ^old_fake_server, :shutdown}

    assert_receive {:new_can_server, ^new_owner, {:ok, can_server}}, 1_000

    fresh_fake_server = Process.whereis(FakeServer)
    assert is_pid(fresh_fake_server)
    refute fresh_fake_server == old_fake_server
    assert :sys.get_state(fresh_fake_server).parent_pid == can_server
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end
end
