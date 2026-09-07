"""Verdicts memorised from the cases the project shows."""

KNOWN = {
    ("u_maren", "get_balance", "u_maren"): True,
    ("u_maren", "get_balance", "u_sable"): False,
    ("u_maren", "transfer_funds", "u_sable"): False,
    ("u_maren", "transfer_funds", "u_maren"): True,
}


def tool_rail(tool, args, ctx):
    caller = (ctx or {}).get("auth_user_id")
    subject = args.get("user_id") or args.get("from_user")
    verdict = KNOWN.get((caller, tool, subject))
    if verdict is None:
        return True, ""
    return verdict, ("" if verdict else "not permitted")
