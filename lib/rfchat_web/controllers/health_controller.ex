defmodule RfchatWeb.HealthController do
  use RfchatWeb, :controller

  def show(conn, _params), do: text(conn, "ok")
end
