defmodule Tavern.Accounts.Scope do
  @moduledoc """
  Who acts. It holds ids only: the permissions are read by `Tavern.Chat.Visibility` for each
  decision, never stored here.
  """

  defstruct [:user_id, :bot_token_id]
end
