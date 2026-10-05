defmodule FuzzySearch.Router do
  @moduledoc """
  HTTP API.

    * `GET /search?q=helo&backend=defk&k=10` - top-k matches plus server-side compute time
    * `GET /health` - liveness probe; its latency under load shows scheduler fairness
  """
  use Plug.Router

  plug :match
  plug Plug.Parsers, parsers: [], pass: ["*/*"]
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/search" do
    params = Plug.Conn.fetch_query_params(conn).query_params

    with q when is_binary(q) and q != "" <- params["q"],
         {:ok, backend} <- parse_backend(params["backend"] || "defk"),
         {k, ""} when k in 1..100 <- Integer.parse(params["k"] || "10") do
      {micros, results} = :timer.tc(fn -> FuzzySearch.search(q, backend, k) end)

      body =
        JSON.encode!(%{
          query: q,
          backend: backend,
          micros: micros,
          results: Enum.map(results, fn {w, d} -> %{word: w, distance: d} end)
        })

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    else
      _ -> send_resp(conn, 400, "usage: /search?q=<word>&backend=elixir|defk|blocking&k=1..100")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp parse_backend(b) do
    case Enum.find(FuzzySearch.backends(), &(Atom.to_string(&1) == b)) do
      nil -> :error
      backend -> {:ok, backend}
    end
  end
end
