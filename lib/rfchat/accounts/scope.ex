defmodule Rfchat.Accounts.Scope do
  @moduledoc false

  defstruct [:user, :membership, roles: [], base_permissions: 0]
end
