defmodule TavernWeb.ServerComponents do
  @moduledoc false

  defdelegate mobile_overlays(assigns), to: TavernWeb.ServerComponents.Shell
  defdelegate mobile_channel_drawer(assigns), to: TavernWeb.ServerComponents.Shell
  defdelegate members_drawer(assigns), to: TavernWeb.ServerComponents.Shell
  defdelegate active_channel_view(assigns), to: TavernWeb.ServerComponents.Messages
end
