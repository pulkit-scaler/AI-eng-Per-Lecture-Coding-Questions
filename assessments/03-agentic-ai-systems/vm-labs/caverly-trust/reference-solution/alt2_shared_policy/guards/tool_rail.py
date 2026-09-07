"""Same policy, expressed per tool instead of as permission strings."""
from trust_kit import bank

# tool -> role -> scope, where scope is self, tenant or any, and a missing
# entry means the role may not use the tool at all.
POLICY = {
    "get_balance": {"customer": "self", "support": "tenant", "admin": "tenant"},
    "get_transactions": {"customer": "self", "support": "tenant", "admin": "tenant"},
    "get_profile": {"customer": "self", "support": "tenant", "admin": "tenant"},
    "transfer_funds": {"customer": "self", "admin": "tenant"},
    "get_kb_article": {"customer": "any", "support": "any", "admin": "any"},
}


def tool_rail(tool, args, ctx):
    caller = (ctx or {}).get("auth_user_id")
    role = bank.USER_ROLES.get(caller)
    if role is None:
        return False, "unknown caller %r" % caller
    table = POLICY.get(tool)
    if table is None:
        return False, "unknown tool %r" % tool
    scope = table.get(role)
    if scope is None:
        return False, "role %s may not use %s" % (role, tool)
    if scope == "any":
        return True, ""
    subject = args.get(bank.SUBJECT_ARG.get(tool) or "")
    if scope == "self":
        if subject == caller:
            return True, ""
        return False, "scope self: %s may not use %s on %s" % (caller, tool, subject)
    home, target = bank.tenant_of(caller), bank.tenant_of(subject)
    if home is not None and home == target:
        return True, ""
    return False, "tenant isolation: %s in %s, %s in %s" % (caller, home, subject, target)
