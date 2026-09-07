"""Layer 3: a badge reader in front of every tool.

No model in this file. A role either holds the permission or it does not, and
tenant isolation is checked on the account being acted on.
"""
from trust_kit import bank

ROLE_PERMISSIONS = {
    "customer": {
        "get_balance:self", "get_transactions:self", "get_profile:self",
        "transfer_funds:self", "get_kb_article",
    },
    "support": {
        "get_balance:tenant", "get_transactions:tenant", "get_profile:tenant",
        "get_kb_article",
    },
    "admin": {
        "get_balance:tenant", "get_transactions:tenant", "get_profile:tenant",
        "transfer_funds:tenant", "get_kb_article",
    },
}


def tool_rail(tool, args, ctx):
    caller = (ctx or {}).get("auth_user_id")
    role = bank.USER_ROLES.get(caller)
    if role is None:
        return False, "unknown caller %r" % caller
    permissions = ROLE_PERMISSIONS.get(role, set())

    if tool == "get_kb_article":
        if "get_kb_article" in permissions:
            return True, ""
        return False, "role %s may not read articles" % role

    subject_arg = bank.SUBJECT_ARG.get(tool)
    if subject_arg is None:
        return False, "unknown tool %r" % tool
    subject = args.get(subject_arg)

    if "%s:self" % tool in permissions:
        if subject == caller:
            return True, ""
        return False, ("role %s may only use %s on its own account "
                       "(caller %s, subject %s)" % (role, tool, caller, subject))

    if "%s:tenant" % tool in permissions:
        home = bank.tenant_of(caller)
        target = bank.tenant_of(subject)
        if home is not None and home == target:
            return True, ""
        return False, ("tenant isolation: caller %s is in %s, subject %s is in %s"
                       % (caller, home, subject, target))

    return False, "role %s has no permission for %s" % (role, tool)
