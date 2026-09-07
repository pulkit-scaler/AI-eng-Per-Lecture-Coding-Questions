"""The three nodes that do the thinking, plus the pause and the router.

Beliefs, desires and intentions are first-class fields of the state rather than
something to be reconstructed from a message log six months later during an
audit.
"""
import json
import re

from pelham_kit import (DESIRES, POLICY_THRESHOLD_USD, VALID_CATEGORIES,
                        get_chat_model)

MODEL = get_chat_model()


def _log(state, entry):
    return list(state.get("audit_log") or []) + [entry]


def perceive(state):
    """Update BELIEFS: what the agent knows about the world right now."""
    request = state.get("request") or {}
    beliefs = {
        "employee": request.get("employee"),
        "amount_usd": request.get("amount_usd"),
        "category": request.get("category"),
        "description": request.get("description"),
        "policy_threshold_usd": POLICY_THRESHOLD_USD,
        "valid_categories": list(VALID_CATEGORIES),
    }
    entry = ("[PERCEIVE] Ingested claim from %s for %s (%s)."
             % (beliefs["employee"], beliefs["amount_usd"], beliefs["category"]))
    return {"beliefs": beliefs, "audit_log": _log(state, entry)}


def _parse_analysis(text):
    """The model fences its JSON. Read it out of whatever it sent."""
    body = (text or "").strip()
    match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", body, re.S)
    if match:
        body = match.group(1)
    else:
        match = re.search(r"\{.*\}", body, re.S)
        if match:
            body = match.group(0)
    try:
        return json.loads(body)
    except Exception:
        return None


def deliberate(state):
    """Set DESIRES, then form an INTENTION from beliefs plus the analysis."""
    beliefs = state.get("beliefs") or {}

    prompt = (
        "You are an expense analyst. Given this claim:\n"
        "Employee: %s\n"
        "Amount: %s\n"
        "Category: %s\n"
        "Description: %s\n\n"
        "Policy:\n"
        "- Threshold for auto-approval: %s\n"
        "- Valid categories: %s\n\n"
        "Reply in strict JSON with keys: category_valid (bool), risk_level "
        "(low/medium/high), reasoning (one sentence)."
        % (beliefs.get("employee"), beliefs.get("amount_usd"),
           beliefs.get("category"), beliefs.get("description"),
           beliefs.get("policy_threshold_usd"),
           beliefs.get("valid_categories")))

    analysis = _parse_analysis(MODEL.invoke(prompt).content)
    if analysis is None:
        # A reply nobody could read is not permission to auto-approve.
        analysis = {
            "category_valid": beliefs.get("category") in VALID_CATEGORIES,
            "risk_level": "medium",
            "reasoning": "The analysis could not be read, so this is escalated.",
        }

    try:
        amount = float(beliefs.get("amount_usd") or 0)
    except (TypeError, ValueError):
        amount = float(POLICY_THRESHOLD_USD)

    under_threshold = amount < float(beliefs.get("policy_threshold_usd",
                                                 POLICY_THRESHOLD_USD))
    if under_threshold:
        intention = {"action": "auto_approve",
                     "reason": analysis.get("reasoning", "")}
        route = "auto_approve"
    else:
        intention = {"action": "escalate_to_human",
                     "reason": analysis.get("reasoning", "")}
        route = "escalate"

    entry = ("[DELIBERATE] Analysis=%s. Formed intention: %s."
             % (json.dumps(analysis, sort_keys=True), intention["action"]))
    return {
        "desires": list(DESIRES),
        "intentions": [intention],
        "analysis": analysis,
        "route": route,
        "audit_log": _log(state, entry),
    }


def route_decision(state):
    """Which way out of deliberate. Named for the node it selects."""
    return "auto_approve" if state.get("route") == "auto_approve" \
        else "human_review"


def auto_approve(state):
    beliefs = state.get("beliefs") or {}
    entry = ("[ACT] Auto-approved %s under the policy threshold."
             % beliefs.get("amount_usd"))
    return {"final_status": "APPROVED (auto)", "audit_log": _log(state, entry)}


def human_review(state):
    """Pause here and surface the claim to whoever has to sign it off."""
    from langgraph.types import interrupt

    intentions = state.get("intentions") or [{}]
    payload = {
        "message": "Human approval required",
        "claim": state.get("request"),
        "agent_reasoning": intentions[0].get("reason", ""),
        "options": ["approve", "reject"],
    }
    decision = interrupt(payload)
    entry = "[HUMAN_REVIEW] Received decision: %s." % decision
    return {"human_decision": decision, "audit_log": _log(state, entry)}


def finalize(state):
    """Record the outcome and the action it commits the process to next."""
    decision = (state.get("human_decision") or "").strip().lower()
    if decision == "approve":
        status = "APPROVED (human)"
        intention = {"action": "process_reimbursement",
                     "reason": "A person signed this off"}
    elif decision == "reject":
        status = "REJECTED (human)"
        intention = {"action": "notify_employee_rejection",
                     "reason": "A person declined this"}
    else:
        status = state.get("final_status") or "APPROVED (auto)"
        intention = {"action": "process_reimbursement",
                     "reason": "Auto-approved under the policy threshold"}

    entry = "[FINALIZE] Status=%s. Next action: %s." % (status,
                                                        intention["action"])
    return {
        "final_status": status,
        "intentions": list(state.get("intentions") or []) + [intention],
        "audit_log": _log(state, entry),
    }
