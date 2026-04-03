defmodule RfchatWeb.API.CommandJSON do
  @moduledoc false

  def show(%{result: result}) do
    %{data: result}
  end
end
