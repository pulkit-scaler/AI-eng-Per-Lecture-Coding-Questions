"""The same three stages, carried on an object instead of module functions."""
import json
import re

from pelham_kit import (DESIRES, POLICY_THRESHOLD_USD, VALID_CATEGORIES,
                        get_chat_model)


class Analyst:
    def __init__(self):
        self.model = get_chat_model()

    @staticmethod
    def _append(state, entry):
        return list(state.get("audit_log") or []) + [entry]

    def perceive(self, state):
        request = state.get("request") or {}
        beliefs = dict(request)
        beliefs["policy_threshold_usd"] = POLICY_THRESHOLD_USD
        beliefs["valid_categories"] = list(VALID_CATEGORIES)
        return {"beliefs": beliefs,
                "audit_log": self._append(
                    state, "[PERCEIVE] claim from %s for %s in %s"
                    % (beliefs.get("employee"), beliefs.get("amount_usd"),
                       beliefs.get("category")))}

    def _ask(self, beliefs):
        prompt = ("Expense claim for review.\n"
                  "employee: %s\namount: %s\ncategory: %s\ndescription: %s\n"
                  "threshold: %s\napproved categories: %s\n"
                  "Return JSON with category_valid, risk_level and reasoning."
                  % (beliefs.get("employee"), beliefs.get("amount_usd"),
                     beliefs.get("category"), beliefs.get("description"),
                     beliefs.get("policy_threshold_usd"),
                     beliefs.get("valid_categories")))
        raw = self.model.invoke(prompt).content or ""
        for candidate in (re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, re.S),
                          re.search(r"\{.*\}", raw, re.S)):
            if candidate:
                try:
                    return json.loads(candidate.group(1)
                                      if candidate.lastindex else candidate.group(0))
                except Exception:
                    continue
        return {"category_valid": beliefs.get("category") in VALID_CATEGORIES,
                "risk_level": "medium",
                "reasoning": "The analysis could not be read."}

    def deliberate(self, state):
        beliefs = state.get("beliefs") or {}
        analysis = self._ask(beliefs)
        try:
            amount = float(beliefs.get("amount_usd") or 0)
        except (TypeError, ValueError):
            amount = float(POLICY_THRESHOLD_USD)
        clear = (amount < POLICY_THRESHOLD_USD
                 and bool(analysis.get("category_valid"))
                 and analysis.get("risk_level") == "low")
        action = "auto_approve" if clear else "escalate_to_human"
        return {"desires": list(DESIRES),
                "intentions": [{"action": action,
                                "reason": analysis.get("reasoning", "")}],
                "analysis": analysis,
                "route": "auto_approve" if clear else "escalate",
                "audit_log": self._append(
                    state, "[DELIBERATE] risk=%s valid=%s -> %s"
                    % (analysis.get("risk_level"),
                       analysis.get("category_valid"), action))}

    def human_review(self, state):
        from langgraph.types import interrupt
        first = (state.get("intentions") or [{}])[0]
        decision = interrupt({"message": "Human approval required",
                              "claim": state.get("request"),
                              "agent_reasoning": first.get("reason", ""),
                              "options": ["approve", "reject"]})
        return {"human_decision": decision,
                "audit_log": self._append(
                    state, "[HUMAN_REVIEW] decision %s" % decision)}

    def auto_approve(self, state):
        return {"final_status": "APPROVED (auto)",
                "audit_log": self._append(state, "[ACT] cleared automatically")}

    def finalize(self, state):
        decision = (state.get("human_decision") or "").strip().lower()
        if decision == "approve":
            status, action = "APPROVED (human)", "process_reimbursement"
        elif decision == "reject":
            status, action = "REJECTED (human)", "notify_employee_rejection"
        else:
            status = state.get("final_status") or "APPROVED (auto)"
            action = "process_reimbursement"
        return {"final_status": status,
                "intentions": list(state.get("intentions") or [])
                              + [{"action": action, "reason": "finalised"}],
                "audit_log": self._append(
                    state, "[FINALIZE] status %s next %s" % (status, action))}


ANALYST = Analyst()
perceive = ANALYST.perceive
deliberate = ANALYST.deliberate
human_review = ANALYST.human_review
auto_approve = ANALYST.auto_approve
finalize = ANALYST.finalize


def route_decision(state):
    return "auto_approve" if state.get("route") == "auto_approve" \
        else "human_review"
