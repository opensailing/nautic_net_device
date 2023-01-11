defmodule NauticNet.IngestClient do
  use Tesla

  @base_url Application.compile_env!(:nautic_net_device, :base_url)

  plug Tesla.Middleware.BaseUrl, @base_url
  plug Tesla.Middleware.JSON

  def post_data_set(device_id, ref, proto_binary) do
    post("/api/data_sets", %{
      device_id: device_id,
      ref: ref,
      proto_base64: Base.encode64(proto_binary)
    })
  end
end
