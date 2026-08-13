defmodule RacingOrg.Tracker.Pro.TestSupport.BackendCheckpointRuntimeDirectSource do
  @moduledoc false

  @backend_env "RACING_ORG_BACKEND_PATH"
  @default_backend_root Path.expand("../../../racing_org/website/backend", __DIR__)

  @source_files [
    "lib/racing_org/secure_transport/desired_state_v1.ex",
    "lib/racing_org/secure_transport/desired_state_v1/canonical.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint_runtime/calibration.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint_runtime/polar.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint_runtime/wind_shift.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint.ex"
  ]

  def default_backend_root, do: @default_backend_root

  def snapshot!(fixtures) when is_list(fixtures) do
    backend_root = backend_root!()
    executable = System.find_executable("elixir") || raise "elixir executable is unavailable"
    input_path = temporary_input_path()

    try do
      File.write!(input_path, :erlang.term_to_binary(fixtures, [:deterministic]))
      script = script(backend_root, executable, input_path)

      {output, status} =
        System.cmd(executable, ["-e", script],
          cd: __DIR__,
          env: [{"ERL_AFLAGS", "+S 2:2"}],
          stderr_to_stdout: true
        )

      if status == 0 do
        case String.split(output, "BACKEND_CHECKPOINT_RUNTIME_FIXTURE:", parts: 2) do
          ["", fixture] ->
            fixture
            |> String.trim()
            |> Base.decode64!()
            |> :erlang.binary_to_term()

          [compiler_output, _fixture] ->
            raise "backend direct-source checkpoint runtime probe emitted compiler output:\n#{compiler_output}"

          _ ->
            raise "backend direct-source checkpoint runtime probe emitted no fixture:\n#{output}"
        end
      else
        raise "backend direct-source checkpoint runtime probe exited with #{status}:\n#{output}"
      end
    after
      File.rm(input_path)
    end
  end

  def backend_root! do
    root = System.get_env(@backend_env, @default_backend_root) |> Path.expand()
    missing = Enum.reject(@source_files, &File.regular?(Path.join(root, &1)))

    if missing == [] do
      root
    else
      raise """
      checkpoint runtime backend direct source is unavailable at #{root}

      Set #{@backend_env} to the backend root containing:
      #{Enum.map_join(missing, "\n", &"  - #{&1}")}
      """
    end
  end

  defp temporary_input_path do
    Path.join(
      System.tmp_dir!(),
      "backend-checkpoint-runtime-#{System.unique_integer([:positive, :monotonic])}.term"
    )
  end

  defp script(backend_root, executable, input_path) do
    source_paths = Enum.map(@source_files, &Path.join(backend_root, &1))

    """
    Code.put_compiler_option(:no_warn_undefined, :all)

    launcher = #{inspect(executable)}

    unless :code.is_loaded(Mix) == false do
      raise "Mix was loaded before direct backend source evaluation"
    end

    if Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
         application == :racing_org
       end) do
      raise ":racing_org was started before direct backend source evaluation"
    end

    unless Path.basename(launcher) == "elixir" do
      raise "direct backend source launcher was not elixir: \#{launcher}"
    end

    Enum.each(#{inspect(source_paths)}, &Code.require_file/1)

    defmodule BackendCheckpointRuntimeDirectSourceProbe do
      alias RacingOrg.SecureTransport.DesiredStateV1, as: Contract
      alias RacingOrg.SecureTransport.DesiredStateV1.Canonical
      alias RacingOrg.SecureTransport.DesiredStateV1.Checkpoint

      def run(fixtures, isolation) do
        %{
          isolation: isolation,
          runtime_schemas:
            Enum.map(Contract.checkpoint_runtime_schemas(), fn {kind, _code, schema_version} ->
              {kind, schema_version}
            end),
          results: Map.new(fixtures, fn fixture -> {fixture.id, result(fixture)} end)
        }
      end

      defp result(fixture) do
        wire = backend_value(fixture.wire)
        {:ok, canonical_content} =
          Checkpoint.canonical_content(fixture.kind, fixture.schema_version, wire)

        {:ok, content_hash} =
          Checkpoint.content_hash(fixture.kind, fixture.schema_version, canonical_content)

        checkpoint_attrs = Map.put(fixture.checkpoint_attrs, :content_hash, content_hash)
        {:ok, checkpoint_hash} = Checkpoint.hash(checkpoint_attrs)

        {:ok, decoded} =
          Checkpoint.decode_canonical_content(
            fixture.kind,
            fixture.schema_version,
            canonical_content
          )

        authority_validation =
          if fixture.authority do
            Checkpoint.validate_authority(
              fixture.kind,
              fixture.schema_version,
              canonical_content,
              fixture.authority
            )
          end

        mismatched_authority_validation =
          if fixture.authority do
            mismatched = Map.update!(fixture.authority, :credential_epoch, &(&1 + 1))

            Checkpoint.validate_authority(
              fixture.kind,
              fixture.schema_version,
              canonical_content,
              mismatched
            )
          end

        %{
          canonical_content: canonical_content,
          content_hash: content_hash,
          checkpoint_hash: checkpoint_hash,
          decoded: portable(decoded),
          authority_validation: authority_validation,
          mismatched_authority_validation: mismatched_authority_validation
        }
      end

      defp backend_value({:canonical_bytes, data}) when is_binary(data),
        do: Canonical.bytes(data)

      defp backend_value(value) when is_map(value) do
        Map.new(value, fn {key, nested} -> {backend_value(key), backend_value(nested)} end)
      end

      defp backend_value(value) when is_list(value), do: Enum.map(value, &backend_value/1)

      defp backend_value(value) when is_tuple(value) do
        value
        |> Tuple.to_list()
        |> Enum.map(&backend_value/1)
        |> List.to_tuple()
      end

      defp backend_value(value), do: value

      defp portable(%Canonical.Bytes{data: data}), do: {:canonical_bytes, data}

      defp portable(value) when is_map(value) do
        Map.new(value, fn {key, nested} -> {portable(key), portable(nested)} end)
      end

      defp portable(value) when is_list(value), do: Enum.map(value, &portable/1)

      defp portable(value) when is_tuple(value) do
        value
        |> Tuple.to_list()
        |> Enum.map(&portable/1)
        |> List.to_tuple()
      end

      defp portable(value), do: value
    end

    isolation = %{
      mix_loaded?: :code.is_loaded(Mix) != false,
      racing_org_started?:
        Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
          application == :racing_org
        end),
      launcher: launcher,
      launcher_basename: Path.basename(launcher)
    }

    fixtures = #{inspect(input_path)} |> File.read!() |> :erlang.binary_to_term()
    snapshot = BackendCheckpointRuntimeDirectSourceProbe.run(fixtures, isolation)
    IO.write("BACKEND_CHECKPOINT_RUNTIME_FIXTURE:" <> (snapshot |> :erlang.term_to_binary() |> Base.encode64()))
    """
  end
end
