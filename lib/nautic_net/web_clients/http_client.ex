defmodule NauticNet.WebClients.HTTPClient do
  use Tesla

  @api_endpoint Application.compile_env!(:nautic_net_device, :api_endpoint)

  plug Tesla.Middleware.BaseUrl, @api_endpoint
  plug Tesla.Middleware.JSON

  def post_data_set(proto_binary) do
    post("/api/data_sets", %{proto_base64: Base.encode64(proto_binary)})
    |> case do
      {:ok, %Tesla.Env{status: status} = env} when status >= 200 and status <= 299 -> {:ok, env}
      {:ok, %Tesla.Env{status: status}} -> {:error, "Server responded with #{status} status"}
      {:error, reason} -> {:error, reason}
    end
  end
end
