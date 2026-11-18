defmodule TavernWeb.GuildComponents do
  @moduledoc false

  defdelegate mobile_overlays(assigns), to: TavernWeb.GuildComponents.Shell
  defdelegate mobile_channel_drawer(assigns), to: TavernWeb.GuildComponents.Shell
  defdelegate members_drawer(assigns), to: TavernWeb.GuildComponents.Shell
  defdelegate active_channel_view(assigns), to: TavernWeb.GuildComponents.Messages
end
