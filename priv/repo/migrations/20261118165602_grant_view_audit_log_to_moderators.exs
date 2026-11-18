defmodule Rfchat.Repo.Migrations.GrantViewAuditLogToModerators do
  @moduledoc """
  Adds the `view_audit_log` bit (1 << 23) to every role that already holds a moderation bit
  (`kick_members`, `ban_members` or `moderate_members`, bits 17 to 19). Those roles could read
  moderation cases before the bit existed, so they keep that access.

  The masks are literal integers so the migration does not depend on the app's modules.
  """
  use Ecto.Migration

  @view_audit_log 8_388_608
  @moderation_bits 917_504

  def up do
    execute """
    UPDATE roles
    SET permissions = permissions | #{@view_audit_log}
    WHERE (permissions & #{@moderation_bits}) <> 0
    """
  end

  def down do
    execute """
    UPDATE roles
    SET permissions = permissions & ~#{@view_audit_log}
    WHERE (permissions & #{@view_audit_log}) <> 0
    """
  end
end
