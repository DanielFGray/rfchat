defmodule RfchatWeb.API.MessageJSON do
  @moduledoc false

  def index(%{messages: messages}) do
    %{data: messages}
  end

  def show(%{message: message}) do
    %{data: message}
  end
end
