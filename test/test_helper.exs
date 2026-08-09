Code.require_file("support/identity_provider_test_support.exs", __DIR__)
Code.require_file("support/recovery_v2_test_support.exs", __DIR__)
Code.require_file("support/desired_state_test_support.exs", __DIR__)

authority_services = [
  RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Root,
  RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry.Store,
  RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRegistry
]

Enum.each(authority_services, fn service ->
  case Process.whereis(service) do
    nil ->
      {:ok, service_pid} = service.start_link()
      Process.unlink(service_pid)

    _service_pid ->
      :ok
  end
end)

ExUnit.start()
