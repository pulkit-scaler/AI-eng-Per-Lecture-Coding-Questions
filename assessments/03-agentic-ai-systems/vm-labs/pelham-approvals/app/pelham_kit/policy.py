"""The written expense policy, as data. Provided, do not modify."""

# Claims at or above this figure need a person to sign them off.
POLICY_THRESHOLD_USD = 100

# Anything outside this list needs a person to look at it, at any amount.
VALID_CATEGORIES = ["meals", "travel", "software", "office_supplies"]

# Business goals. These are set by the people who own the process, not by a
# model, and they do not change from claim to claim.
DESIRES = [
    "Approve legitimate expenses quickly",
    "Prevent fraudulent or out-of-policy claims",
    "Escalate anything ambiguous or high-value to a person",
]
